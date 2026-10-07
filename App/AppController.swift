import AppKit
import Foundation
import LocalFlowCore
import ServiceManagement
import SwiftUI
import UserNotifications

/// Main-thread coordinator: hotkey → state machine → recorder → engine → paste.
@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    enum IconState { case idle, recording, processing }
    enum SettingsTab: String { case general, cleanup, models, privacy }

    @Published private(set) var icon: IconState = .idle
    @Published private(set) var statusLine = "Starting…"
    @Published private(set) var config: AppConfig = .default
    @Published private(set) var permissions = Permissions.snapshot()
    @Published private(set) var modelState: DictationEngine.ModelState = .notLoaded
    @Published private(set) var launchAtLogin = false
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var modelsMissing = false
    @Published private(set) var modelStatus: ModelManager.Status?
    @Published private(set) var hotkeyActive = false
    /// Incremented to ask the SwiftUI layer (which owns `openSettings`) to show the Settings window.
    @Published private(set) var settingsRequests = 0
    /// Tab the Settings window should select on its next open.
    @Published private(set) var requestedSettingsTab: SettingsTab = .general
    /// Incremented to ask the SwiftUI layer to open the History window.
    @Published private(set) var historyRequests = 0
    /// Newest first; mirrors history.jsonl.
    @Published private(set) var history: [HistoryEntry] = []

    private var engine: DictationEngine
    private let recorder = AudioRecorder()
    private let monitor = HotkeyMonitor()
    private var machine = HotkeyStateMachine()
    private let store = AppConfigStore()
    private let historyStore = DictationHistory(url: LocalFlowPaths.historyFile)
    private let logger = FlowLogger.shared
    private var ticker: Timer?
    private var inFlight = 0
    private var recordingStartedAt = Date()

    private init() {
        engine = DictationEngine(config: .default)
    }

    // MARK: - Lifecycle

    func start() {
        try? LocalFlowPaths.ensureDirectories()
        ModelManager.enforceOffline()
        let load = store.load()
        config = load.config
        if let e = load.error { logger.error(e) }
        logger.info("LocalFlow launched; config \(load.created ? "created" : "loaded"); hotkey=\(config.hotkey.rawValue)")
        engine = DictationEngine(config: config)
        machine = HotkeyStateMachine(maxRecordingSeconds: TimeInterval(config.maxRecordingSeconds))
        monitor.key = config.hotkey
        monitor.onHotkey = { [weak self] down in self?.hotkey(down: down) }
        monitor.onEscape = { [weak self] in self?.escape() ?? false }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task {
            await Permissions.requestAll()
            self.refreshPermissions()
        }
        syncLaunchAtLogin()
        loadModels()
        DistributedNotificationCenter.default().addObserver(forName: LocalFlowIPC.openSettings, object: nil, queue: .main) { [weak self] _ in
            self?.showSettings()
        }
        DistributedNotificationCenter.default().addObserver(forName: LocalFlowIPC.openHistory, object: nil, queue: .main) { [weak self] _ in
            self?.showHistory()
        }
        reloadHistory()
        // First run on a new Mac: models are not there yet. Open Settings → Models so the
        // Download button is the first thing people see, and say so in a notification.
        if !ModelManager.status(config: config).allPresent {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showSettings(tab: .models)
                self?.notify("Welcome to LocalFlow", "One-time setup: download the two models (~2.8 GB), then grant the permissions macOS asks for.")
            }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refreshStatus()
    }

    func loadModels() {
        modelsMissing = false
        Task {
            modelState = .loading
            refreshStatus()
            await engine.loadModels()
            modelState = await engine.modelState
            if case .missing = modelState { modelsMissing = true }
            refreshModelStatus()
            refreshStatus()
        }
    }

    private var tickCount = 0
    private func tick() {
        apply(machine.handle(.tick, at: Date().timeIntervalSince1970))
        refreshPermissions()
        tickCount += 1
        if tickCount % 5 == 0, NSApp.windows.contains(where: { $0.isVisible && $0.title.contains("Settings") }) { refreshModelStatus() }
    }

    private func refreshPermissions() {
        let snap = Permissions.snapshot()
        if snap != permissions { permissions = snap }
        if !monitor.isActive, snap.inputMonitoring {
            if monitor.start() { logger.info("hotkey tap active (\(monitor.isListenOnly ? "listen-only" : "active"))") }
        }
        if hotkeyActive != monitor.isActive { hotkeyActive = monitor.isActive }
        refreshStatus()
    }

    private func refreshStatus() {
        let model = config.llmModel.split(separator: "/").last.map(String.init) ?? config.llmModel
        var state: String
        switch modelState {
        case .notLoaded: state = "Starting"
        case .loading: state = "Loading models…"
        case .ready: state = machine.isRecording ? "Recording" : (inFlight > 0 ? "Processing" : "Ready")
        case .missing(let stt, let llm):
            state = "Models missing (\(([stt ? "STT" : nil, llm ? "LLM" : nil].compactMap { $0 }).joined(separator: ", "))) — download below"
        case .failed(let msg): state = "Model load failed: \(msg)"
        }
        if let p = downloadProgress { state = String(format: "Downloading models… %.0f%%", p * 100) }
        var line = "\(model) · \(state)"
        if !permissions.allGranted { line += " · Needs: " + permissions.missing.joined(separator: ", ") }
        else if !monitor.isActive { line += " · Hotkey inactive (relaunch)" }
        statusLine = line
        icon = machine.isRecording ? .recording : (inFlight > 0 ? .processing : .idle)
    }

    // MARK: - Hotkey

    private func hotkey(down: Bool) {
        apply(machine.handle(down ? .hotkeyDown : .hotkeyUp, at: Date().timeIntervalSince1970))
    }

    private func escape() -> Bool {
        let out = machine.handle(.escape, at: Date().timeIntervalSince1970)
        apply(out)
        return out.consumeEvent
    }

    private func apply(_ out: HotkeyStateMachine.Output) {
        switch out.action {
        case .none: return
        case .startRecording: startRecording()
        case .stopAndProcess: stopAndProcess()
        case .cancelRecording: cancelRecording()
        }
        refreshStatus()
    }

    private func startRecording() {
        guard modelState == .ready else {
            machine.reset()
            notify("LocalFlow isn't ready", modelsMissing ? "Download the models from the menu bar first." : "Models are still loading.")
            return
        }
        guard permissions.microphone else {
            machine.reset()
            notify("Microphone access needed", "System Settings → Privacy & Security → Microphone → LocalFlow.")
            return
        }
        do {
            try recorder.start()
            recordingStartedAt = Date()
            NSSound(named: "Tink")?.play()
        } catch {
            machine.reset()
            logger.error("recorder start failed: \(error)")
            notify("Could not start recording", error.localizedDescription)
        }
    }

    private func stopAndProcess() {
        let samples = recorder.stop()
        let seconds = Date().timeIntervalSince(recordingStartedAt)
        NSSound(named: "Pop")?.play()
        inFlight += 1
        refreshStatus()
        Task {
            let outcome = await engine.process(samples: samples, recordSeconds: seconds)
            inFlight -= 1
            if let text = outcome.text {
                let pasted = deliver(text)
                if config.historyEnabled {
                    let app = NSWorkspace.shared.frontmostApplication?.localizedName
                    historyStore.append(HistoryEntry(raw: outcome.raw, cleaned: text, seconds: seconds, app: app,
                                                     pasted: pasted, usedLLM: outcome.usedLLM))
                    reloadHistory()
                }
            } else if let reason = outcome.skippedReason, reason.hasPrefix("error") || reason == "models not ready" {
                notify("Dictation failed", reason)
            }
            refreshStatus()
        }
    }

    private func cancelRecording() {
        recorder.cancel()
    }

    // MARK: - Output

    /// Copies the text to the clipboard and pastes it into the focused field. Returns true when ⌘V was sent.
    @discardableResult
    private func deliver(_ text: String) -> Bool {
        if Paster.secureInputActive {
            Paster.copyOnly(text)
            notify("Secure input field", "Pasting is blocked here; the text is on your clipboard.")
            return false
        }
        guard permissions.accessibility else {
            Paster.copyOnly(text)
            notify("Ready to paste", "Enable Accessibility for LocalFlow to paste automatically. The text is on your clipboard.")
            return false
        }
        if !Paster.paste(text, restorePrevious: !config.keepOnClipboard) {
            notify("Ready to paste", "Couldn't send ⌘V; the text is on your clipboard.")
            return false
        }
        return true
    }

    // MARK: - History

    func reloadHistory() {
        history = historyStore.load()
    }

    func deleteHistory(id: UUID) {
        historyStore.delete(id: id)
        reloadHistory()
    }

    func clearHistory() {
        historyStore.clear()
        reloadHistory()
        logger.info("history cleared")
    }

    func copyToClipboard(_ text: String) {
        Paster.copyOnly(text)
    }

    func revealHistoryFile() {
        NSWorkspace.shared.activateFileViewerSelecting([LocalFlowPaths.historyFile])
    }

    func showHistory() {
        logger.info("history window requested")
        NSApp.activate(ignoringOtherApps: true)
        historyRequests += 1
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }

    // MARK: - Config changes (menu + Settings window)

    /// Mutate the config, persist it, and push every changed key to the right component.
    func update(_ transform: (inout AppConfig) -> Void) {
        var new = config
        transform(&new)
        applyConfig(new)
    }

    /// SwiftUI binding onto one config key; writes go through `applyConfig`.
    func binding<T>(_ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(get: { self.config[keyPath: keyPath] },
                set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    func applyConfig(_ new: AppConfig) {
        let old = config
        guard new != old else { return }
        config = new
        do { try store.save(new) } catch { logger.error("config save failed: \(error)") }
        if old.hotkey != new.hotkey { monitor.key = new.hotkey; logger.info("hotkey → \(new.hotkey.rawValue)") }
        if old.maxRecordingSeconds != new.maxRecordingSeconds { machine.maxRecordingSeconds = TimeInterval(new.maxRecordingSeconds) }
        if old.launchAtLogin != new.launchAtLogin { syncLaunchAtLogin(force: true) }
        let modelChanged = old.sttModel != new.sttModel || old.llmModel != new.llmModel
        Task {
            await engine.update(config: new)
            if modelChanged {
                engine = DictationEngine(config: new)
                loadModels()
            }
            refreshModelStatus()
            refreshStatus()
        }
    }

    func toggleCleanup() { update { $0.cleanupEnabled.toggle() } }
    func togglePasteRaw() { update { $0.pasteRawTranscript.toggle() } }
    func toggleLaunchAtLogin() { update { $0.launchAtLogin.toggle() } }

    private func syncLaunchAtLogin(force: Bool = false) {
        let service = SMAppService.mainApp
        let installed = Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/") || Bundle.main.bundlePath.hasPrefix("/Applications/")
        do {
            if config.launchAtLogin, service.status != .enabled, installed || force {
                try service.register()
                logger.info("login item registered (\(Bundle.main.bundlePath))")
            } else if !config.launchAtLogin, service.status == .enabled {
                try service.unregister()
                logger.info("login item unregistered")
            }
        } catch {
            logger.error("login item: \(error)")
        }
        launchAtLogin = service.status == .enabled
    }

    /// Open the SwiftUI Settings scene programmatically (⌘, equivalent). The menu bar label view
    /// observes `settingsRequests` and calls SwiftUI's `openSettings` action.
    func showSettings(tab: SettingsTab = .general) {
        logger.info("settings window requested (\(tab.rawValue))")
        requestedSettingsTab = tab
        NSApp.activate(ignoringOtherApps: true)
        settingsRequests += 1
    }

    func openConfig() { NSWorkspace.shared.open(LocalFlowPaths.configFile) }
    func openLog() { NSWorkspace.shared.open(LocalFlowPaths.logFile) }
    func revealModelsFolder() { NSWorkspace.shared.activateFileViewerSelecting([LocalFlowPaths.modelsDir]) }

    /// Re-read config.json (edited by hand) and apply whatever changed.
    func reloadConfig() {
        let load = store.load()
        if let e = load.error { logger.error(e) }
        applyConfig(load.config)
        logger.info("config reloaded")
    }

    func refreshModelStatus() {
        modelStatus = ModelManager.status(config: config)
    }

    func downloadModels() {
        guard downloadProgress == nil else { return }
        downloadProgress = 0
        refreshStatus()
        let cfg = config
        Task {
            do {
                let status = ModelManager.status(config: cfg)
                if !status.sttPresent {
                    try await ModelManager.downloadSTT(sttModel: cfg.sttModel) { p in
                        Task { @MainActor in self.downloadProgress = p * 0.2; self.refreshStatus() }
                    }
                }
                if !status.llmPresent {
                    try await ModelManager.downloadLLM(id: cfg.llmModel) { p in
                        Task { @MainActor in self.downloadProgress = 0.2 + p * 0.8; self.refreshStatus() }
                    }
                }
                downloadProgress = nil
                logger.info("models downloaded")
                loadModels()
            } catch {
                downloadProgress = nil
                modelState = .failed("download: \(error.localizedDescription)")
                logger.error("download failed: \(error)")
                refreshStatus()
            }
        }
    }

    func quit() {
        recorder.cancel()
        monitor.stop()
        NSApplication.shared.terminate(nil)
    }
}
