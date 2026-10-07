import Foundation

/// Outcome of processing one recording.
public struct DictationOutcome: Sendable {
    /// Text to paste; nil when nothing should be pasted (silence, empty transcript).
    public var text: String?
    public var raw: String
    public var skippedReason: String?
    public var fallbackReason: String?
    public var sttMs: Double
    public var llmMs: Double
    public var totalMs: Double
    public var usedLLM: Bool
}

/// Owns the two models and runs record → STT → cleanup, one request at a time.
/// Being an actor, a second recording that finishes while one is processing simply queues.
public actor DictationEngine {
    public enum ModelState: Sendable, Equatable {
        case notLoaded
        case missing(stt: Bool, llm: Bool)
        case loading
        case ready
        case failed(String)
    }

    public private(set) var modelState: ModelState = .notLoaded
    public private(set) var config: AppConfig
    private let transcriber = Transcriber()
    private var backend: MLXCleanupBackend?
    private let logger: FlowLogger
    private let history: DictationHistory

    public init(config: AppConfig, logger: FlowLogger = .shared) {
        self.config = config
        self.logger = logger
        self.history = DictationHistory(url: LocalFlowPaths.historyFile)
    }

    public var modelsPresent: ModelManager.Status { ModelManager.status(config: config) }

    /// Load both models from disk and warm them up. Never downloads.
    public func loadModels() async {
        ModelManager.enforceOffline()
        let status = ModelManager.status(config: config)
        guard status.allPresent else {
            modelState = .missing(stt: !status.sttPresent, llm: !status.llmPresent)
            logger.warn("models missing: stt=\(status.sttPresent) llm=\(status.llmPresent)")
            return
        }
        modelState = .loading
        let t0 = Date()
        do {
            try await transcriber.load(sttModel: config.sttModel)
            try await transcriber.warmUp()
            let t1 = Date()
            let be = MLXCleanupBackend(modelID: config.llmModel, directory: status.llmDirectory, logger: logger)
            try await be.load()
            let system = CleanupPrompt.system(vocabulary: config.vocabulary)
            let prefix = try await be.prepare(system: system)
            try await be.warmUp(system: system)
            backend = be
            modelState = .ready
            logger.info(String(format: "models ready: stt %.0fms, llm %.0fms (prefix %d tokens)",
                               t1.timeIntervalSince(t0) * 1000, Date().timeIntervalSince(t1) * 1000, prefix))
        } catch {
            modelState = .failed(error.localizedDescription)
            logger.error("model load failed: \(error)")
        }
    }

    /// Apply a new config. Re-prepares the prompt prefix when the vocabulary changed;
    /// a model change requires `loadModels()` again (caller decides).
    public func update(config newConfig: AppConfig) async {
        let old = config
        config = newConfig
        if old.vocabulary != newConfig.vocabulary, let backend {
            do { try await backend.prepare(system: CleanupPrompt.system(vocabulary: newConfig.vocabulary)) }
            catch { logger.error("prefix re-prepare failed: \(error)") }
        }
    }

    public var needsModelReload: (AppConfig) -> Bool {
        { [config] new in new.sttModel != config.sttModel || new.llmModel != config.llmModel }
    }

    public func process(samples: [Float], recordSeconds: Double) async -> DictationOutcome {
        let t0 = Date()
        guard modelState == .ready else {
            return DictationOutcome(text: nil, raw: "", skippedReason: "models not ready", fallbackReason: nil,
                                    sttMs: 0, llmMs: 0, totalMs: 0, usedLLM: false)
        }
        if SilenceGuard.isSilent(samples) {
            logger.info(String(format: "skipped: silent recording (%.1f dBFS, %.1fs)", AudioFileLoader.dBFS(samples), recordSeconds))
            return DictationOutcome(text: nil, raw: "", skippedReason: "silent", fallbackReason: nil,
                                    sttMs: 0, llmMs: 0, totalMs: 0, usedLLM: false)
        }
        do {
            let stt = try await transcriber.transcribe(samples: samples)
            let t1 = Date()
            guard TextSanity.isMeaningful(stt.text) else {
                logger.timing([("record", recordSeconds * 1000), ("stt", stt.processingMs)])
                logger.info("skipped: empty transcript")
                return DictationOutcome(text: nil, raw: stt.text, skippedReason: "empty transcript", fallbackReason: nil,
                                        sttMs: stt.processingMs, llmMs: 0, totalMs: t1.timeIntervalSince(t0) * 1000, usedLLM: false)
            }
            let useLLM = config.cleanupEnabled && !config.pasteRawTranscript
            let pipeline = CleanupPipeline(backend: backend, vocabulary: config.vocabulary, cleanupEnabled: useLLM)
            let cleaned: CleanupResult
            if config.pasteRawTranscript {
                cleaned = CleanupResult(text: stt.text, raw: stt.text, usedLLM: false)
            } else {
                cleaned = await pipeline.clean(stt.text)
            }
            let total = Date().timeIntervalSince(t0) * 1000
            logger.timing([("record", recordSeconds * 1000), ("stt", stt.processingMs), ("llm", cleaned.llmMs), ("total", total)])
            if let f = cleaned.fallbackReason { logger.warn("cleanup fallback: \(f)") }
            if config.historyEnabled { history.append(raw: stt.text, cleaned: cleaned.text) }
            let text = TextSanity.isMeaningful(cleaned.text) ? cleaned.text : nil
            return DictationOutcome(text: text, raw: stt.text, skippedReason: text == nil ? "empty after cleanup" : nil,
                                    fallbackReason: cleaned.fallbackReason, sttMs: stt.processingMs, llmMs: cleaned.llmMs,
                                    totalMs: total, usedLLM: cleaned.usedLLM)
        } catch {
            logger.error("processing failed: \(error)")
            return DictationOutcome(text: nil, raw: "", skippedReason: "error: \(error.localizedDescription)", fallbackReason: nil,
                                    sttMs: 0, llmMs: 0, totalMs: Date().timeIntervalSince(t0) * 1000, usedLLM: false)
        }
    }
}

/// Opt-in transcript history (historyEnabled). JSON lines: {"ts","raw","cleaned"}.
public final class DictationHistory: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    public init(url: URL) { self.url = url }

    public func append(raw: String, cleaned: String) {
        struct Line: Codable { let ts: String; let raw: String; let cleaned: String }
        let f = ISO8601DateFormatter()
        guard var data = try? JSONEncoder().encode(Line(ts: f.string(from: Date()), raw: raw, cleaned: cleaned)) else { return }
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            try? h.seekToEnd()
            try? h.write(contentsOf: data)
            try? h.close()
        }
    }
}
