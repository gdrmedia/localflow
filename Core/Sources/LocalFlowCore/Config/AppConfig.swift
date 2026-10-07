import Foundation

public enum HotkeyChoice: String, Codable, CaseIterable, Sendable {
    case rightOption = "right_option"
    case fn = "fn"

    public var displayName: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .fn: return "Fn / Globe (🌐)"
        }
    }
}

/// User configuration, persisted as JSON at `LocalFlowPaths.configFile`.
/// Decoding is tolerant: any missing or invalid key falls back to its default.
public struct AppConfig: Codable, Equatable, Sendable {
    public var hotkey: HotkeyChoice
    public var cleanupEnabled: Bool
    public var pasteRawTranscript: Bool
    public var sttModel: String
    public var llmModel: String
    public var historyEnabled: Bool
    public var maxRecordingSeconds: Int
    public var vocabulary: [String]
    public var launchAtLogin: Bool

    public static let defaultSTTModel = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    public static let defaultLLMModel = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

    /// Seed list of brand spellings. Add your own names and products in Settings → Cleanup.
    public static let defaultVocabulary: [String] = [
        "HubSpot", "Webflow", "Shopify", "Figma", "Notion", "Airtable", "GitHub", "Google Docs",
        "ChatGPT", "Claude", "iPhone", "MacBook", "LocalFlow",
    ]

    public static let `default` = AppConfig(
        hotkey: .rightOption,
        cleanupEnabled: true,
        pasteRawTranscript: false,
        sttModel: defaultSTTModel,
        llmModel: defaultLLMModel,
        historyEnabled: false,
        maxRecordingSeconds: 300,
        vocabulary: defaultVocabulary,
        launchAtLogin: true
    )

    public init(hotkey: HotkeyChoice, cleanupEnabled: Bool, pasteRawTranscript: Bool, sttModel: String,
                llmModel: String, historyEnabled: Bool, maxRecordingSeconds: Int, vocabulary: [String], launchAtLogin: Bool = true) {
        self.hotkey = hotkey
        self.cleanupEnabled = cleanupEnabled
        self.pasteRawTranscript = pasteRawTranscript
        self.sttModel = sttModel
        self.llmModel = llmModel
        self.historyEnabled = historyEnabled
        self.maxRecordingSeconds = AppConfig.clampSeconds(maxRecordingSeconds)
        self.vocabulary = vocabulary
        self.launchAtLogin = launchAtLogin
    }

    enum CodingKeys: String, CodingKey {
        case hotkey, cleanupEnabled, pasteRawTranscript, sttModel, llmModel, historyEnabled, maxRecordingSeconds, vocabulary, launchAtLogin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig.default
        hotkey = (try? c.decodeIfPresent(HotkeyChoice.self, forKey: .hotkey)) ?? d.hotkey
        cleanupEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .cleanupEnabled)) ?? d.cleanupEnabled
        pasteRawTranscript = (try? c.decodeIfPresent(Bool.self, forKey: .pasteRawTranscript)) ?? d.pasteRawTranscript
        sttModel = (try? c.decodeIfPresent(String.self, forKey: .sttModel)).flatMap { $0 } ?? d.sttModel
        llmModel = (try? c.decodeIfPresent(String.self, forKey: .llmModel)).flatMap { $0 } ?? d.llmModel
        historyEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .historyEnabled)) ?? d.historyEnabled
        maxRecordingSeconds = AppConfig.clampSeconds((try? c.decodeIfPresent(Int.self, forKey: .maxRecordingSeconds)) ?? d.maxRecordingSeconds)
        vocabulary = (try? c.decodeIfPresent([String].self, forKey: .vocabulary)) ?? d.vocabulary
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? d.launchAtLogin
        if sttModel.trimmingCharacters(in: .whitespaces).isEmpty { sttModel = d.sttModel }
        if llmModel.trimmingCharacters(in: .whitespaces).isEmpty { llmModel = d.llmModel }
    }

    public static func clampSeconds(_ s: Int) -> Int { min(max(s, 1), 3600) }
}

/// Loads and saves `AppConfig`. Creates the file with defaults on first run.
public struct AppConfigStore: Sendable {
    public let url: URL

    public init(url: URL = LocalFlowPaths.configFile) { self.url = url }

    public struct LoadResult: Sendable {
        public var config: AppConfig
        /// true when the file did not exist and was created with defaults
        public var created: Bool
        /// non-nil when the file existed but could not be parsed (defaults were used, file left untouched)
        public var error: String?
    }

    public func load() -> LoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            do {
                try save(.default)
                return LoadResult(config: .default, created: true, error: nil)
            } catch {
                return LoadResult(config: .default, created: false, error: "could not create config: \(error)")
            }
        }
        do {
            let data = try Data(contentsOf: url)
            let cfg = try JSONDecoder().decode(AppConfig.self, from: data)
            return LoadResult(config: cfg, created: false, error: nil)
        } catch {
            return LoadResult(config: .default, created: false, error: "config.json unreadable, using defaults: \(error.localizedDescription)")
        }
    }

    public func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(config)
        try data.write(to: url, options: .atomic)
    }
}
