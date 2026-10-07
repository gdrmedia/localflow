import AppKit
import SwiftUI
import LocalFlowCore

/// Native Settings window (⌘, or "Settings…" in the menu). Every config key is editable here.
/// Toggles, pickers and steppers apply immediately; text fields apply on "Apply".
struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var tab: AppController.SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab(controller: controller)
                .tabItem { Label("General", systemImage: "keyboard") }
                .tag(AppController.SettingsTab.general)
            CleanupTab(controller: controller)
                .tabItem { Label("Cleanup", systemImage: "text.badge.checkmark") }
                .tag(AppController.SettingsTab.cleanup)
            ModelsTab(controller: controller)
                .tabItem { Label("Models", systemImage: "cpu") }
                .tag(AppController.SettingsTab.models)
            PrivacyTab(controller: controller)
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
                .tag(AppController.SettingsTab.privacy)
        }
        .frame(width: 580, height: 470)
        .onAppear {
            // LSUIElement apps are never active, so the Settings window would open behind everything.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.title.contains("Settings") }?.makeKeyAndOrderFront(nil)
            tab = controller.requestedSettingsTab
            controller.refreshModelStatus()
        }
        .onChange(of: controller.settingsRequests) { _, _ in tab = controller.requestedSettingsTab }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
            Section("Hotkey") {
                Picker("Push-to-talk key", selection: controller.binding(\.hotkey)) {
                    ForEach(HotkeyChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if controller.config.hotkey == .fn {
                    Text("Fn/Globe only works when System Settings → Keyboard → “Press 🌐 key to” is set to **Do Nothing**.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                LabeledContent("Hotkey listener") {
                    Text(controller.hotkeyActive ? "active" : "inactive — grant Input Monitoring and relaunch")
                        .foregroundStyle(controller.hotkeyActive ? .green : .orange)
                }
                Text("Hold to record, release to transcribe. Double-tap for hands-free, tap once to stop. Esc cancels. Presses under 250 ms are ignored.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Recording") {
                Stepper(value: controller.binding(\.maxRecordingSeconds), in: 10...3600, step: 10) {
                    LabeledContent("Maximum recording length", value: "\(controller.config.maxRecordingSeconds) s")
                }
                Text("Recording stops and is processed automatically when the limit is reached.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Output") {
                Text("The result is always copied to the clipboard and pasted into the focused field with ⌘V.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Keep the text on the clipboard after pasting", isOn: controller.binding(\.keepOnClipboard))
                Text("Off = your previous clipboard contents are restored half a second after the paste.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch LocalFlow at login", isOn: controller.binding(\.launchAtLogin))
                LabeledContent("Login item status", value: controller.launchAtLogin ? "registered" : "not registered")
            }
            Section("Status") {
                Text(controller.statusLine).font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Cleanup

private struct CleanupTab: View {
    @ObservedObject var controller: AppController
    @State private var vocabText = ""
    @State private var loaded = false

    private var currentLines: [String] {
        vocabText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var dirty: Bool { currentLines != controller.config.vocabulary }

    var body: some View {
        Form {
            Section("Text cleanup") {
                Toggle("Clean up with the local LLM", isOn: controller.binding(\.cleanupEnabled))
                Text("Removes fillers (um, uh, like…), applies self-corrections (“no sorry, I meant…”), fixes punctuation and numbers. Off = capitalization and a period only.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Paste the raw transcript instead (skip all cleanup)", isOn: controller.binding(\.pasteRawTranscript))
            }
            Section("Preferred spellings") {
                Text("Names and brands, one per line. They are given to the cleanup model and enforced afterwards (“hub spot” → HubSpot).")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $vocabText)
                    .font(.body.monospaced())
                    .frame(minHeight: 150)
                    .accessibilityLabel("Preferred spellings")
                HStack {
                    Button("Apply spellings") { controller.update { $0.vocabulary = currentLines } }
                        .disabled(!dirty)
                        .keyboardShortcut(.defaultAction)
                    Button("Reset to defaults") { vocabText = AppConfig.defaultVocabulary.joined(separator: "\n") }
                    Spacer()
                    Text(dirty ? "unsaved changes" : "\(controller.config.vocabulary.count) terms")
                        .font(.callout).foregroundStyle(dirty ? .orange : .secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { if !loaded { vocabText = controller.config.vocabulary.joined(separator: "\n"); loaded = true } }
        .onChange(of: controller.config.vocabulary) { _, new in
            if !dirty || currentLines == new { vocabText = new.joined(separator: "\n") }
        }
    }
}

// MARK: - Models

private struct ModelsTab: View {
    @ObservedObject var controller: AppController
    @State private var stt = ""
    @State private var llm = ""
    @State private var loaded = false

    private var dirty: Bool { stt != controller.config.sttModel || llm != controller.config.llmModel }

    var body: some View {
        Form {
            Section("Models") {
                TextField("Speech-to-text (Core ML, FluidAudio)", text: $stt)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Speech model")
                TextField("Cleanup LLM (MLX, Hugging Face id)", text: $llm)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Cleanup model")
                HStack {
                    Button("Apply and reload models") {
                        controller.update { $0.sttModel = stt.trimmingCharacters(in: .whitespaces); $0.llmModel = llm.trimmingCharacters(in: .whitespaces) }
                    }
                    .disabled(!dirty)
                    Button("Revert") { stt = controller.config.sttModel; llm = controller.config.llmModel }
                        .disabled(!dirty)
                    Spacer()
                    Text(dirty ? "unsaved changes" : "").font(.callout).foregroundStyle(.orange)
                }
                Text("Any mlx-community Qwen3 / Qwen3.5 4-bit repo works for the LLM. Changing a model requires downloading it (below) and reloads both models.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("On disk") {
                if let s = controller.modelStatus {
                    statusRow("Speech model", present: s.sttPresent, bytes: s.sttBytes)
                    statusRow("Cleanup model", present: s.llmPresent, bytes: s.llmBytes)
                } else {
                    Text("Checking…").foregroundStyle(.secondary)
                }
                LabeledContent("Engine") { Text(modelStateText) }
                HStack {
                    Button(controller.downloadProgress == nil ? "Download missing models" : "Downloading…") { controller.downloadModels() }
                        .disabled(controller.downloadProgress != nil || (controller.modelStatus?.allPresent ?? false))
                    if let p = controller.downloadProgress {
                        ProgressView(value: p).frame(width: 160)
                    }
                    Spacer()
                    Button("Reveal models folder") { controller.revealModelsFolder() }
                }
                Text("Downloading is the only time LocalFlow uses the network. Models live in ~/Library/Application Support/LocalFlow/models.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if !loaded { stt = controller.config.sttModel; llm = controller.config.llmModel; loaded = true }
            controller.refreshModelStatus()
        }
        .onChange(of: controller.config.sttModel) { _, v in if !dirty { stt = v } }
        .onChange(of: controller.config.llmModel) { _, v in if !dirty { llm = v } }
    }

    private var modelStateText: String {
        switch controller.modelState {
        case .notLoaded: return "not loaded"
        case .loading: return "loading…"
        case .ready: return "ready"
        case .missing: return "models missing"
        case .failed(let m): return "failed: \(m)"
        }
    }

    private func statusRow(_ label: String, present: Bool, bytes: Int64) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Image(systemName: present ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(present ? .green : .red)
                Text(present ? ModelManager.humanBytes(bytes) : "missing")
            }
        }
    }
}

// MARK: - Privacy

private struct PrivacyTab: View {
    @ObservedObject var controller: AppController
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Dictation history") {
                Toggle("Keep a history of dictations (viewable in the History window)", isOn: controller.binding(\.historyEnabled))
                Text("Every dictation is stored in clear text in history.jsonl on this Mac only. The log never contains transcripts.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Open History") { controller.showHistory() }
                    Button("Clear History…") { confirmClear = true }.disabled(controller.history.isEmpty)
                    Spacer()
                    Text(controller.history.isEmpty ? "" : "\(controller.history.count) stored").font(.callout).foregroundStyle(.secondary)
                }
                .confirmationDialog("Delete all \(controller.history.count) dictations?", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("Delete All", role: .destructive) { controller.clearHistory() }
                    Button("Cancel", role: .cancel) {}
                }
            }
            Section("Files") {
                HStack {
                    Button("Open Log") { controller.openLog() }
                    Button("Open config.json") { controller.openConfig() }
                    Button("Reload config.json") { controller.reloadConfig() }
                }
            }
            Section("Permissions") {
                permissionRow("Microphone", granted: controller.permissions.microphone, pane: "Privacy_Microphone", why: "to record while you hold the key")
                permissionRow("Accessibility", granted: controller.permissions.accessibility, pane: "Privacy_Accessibility", why: "to paste with ⌘V and swallow Esc")
                permissionRow("Input Monitoring", granted: controller.permissions.inputMonitoring, pane: "Privacy_ListenEvent", why: "to see the hotkey in any app")
                Text("After granting Accessibility or Input Monitoring, quit and reopen LocalFlow.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Network") {
                Text("No telemetry, no analytics, no cloud fallback. After the one-time model download LocalFlow opens no network sockets; verify with scripts/check-network.sh.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(_ name: String, granted: Bool, pane: String, why: String) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(granted ? .green : .red)
                Text(granted ? "granted" : "not granted")
                if !granted {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading) {
                Text(name)
                Text(why).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
