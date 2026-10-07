import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import HuggingFace

// MARK: - swift-transformers → MLXLMCommon bridge (inlined from the MLXHuggingFace macros so no macro plugin is needed)

struct TransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

// MARK: - Backend

/// Qwen3 cleanup model on the GPU via MLX. Loads from a local directory only (zero network).
///
/// Latency lever: the static system prompt's KV cache is computed once (`prepare(system:)`).
/// Each request deep-copies that cache (`KVCache.copy()`, O(prefix) GPU memcpy) and prefills
/// only the transcript tokens. Works for Qwen3 (KVCacheSimple) and Qwen3.5 (MambaCache: copyable, not trimmable).
public actor MLXCleanupBackend: LLMBackend {
    public enum BackendError: Error, LocalizedError {
        case notLoaded
        case modelMissing(URL)
        public var errorDescription: String? {
            switch self {
            case .notLoaded: return "LLM not loaded"
            case .modelMissing(let u): return "LLM files missing at \(u.path)"
            }
        }
    }

    public nonisolated let modelID: String
    public nonisolated let directory: URL

    private var context: ModelContext?
    private var baseParameters = GenerateParameters(maxTokens: nil, temperature: 0)
    private var prefixTokens: [Int] = []
    private var prefixCache: [KVCache]?
    private var prefixSystem: String?
    private var prefixCachingEnabled = true
    private let logger: FlowLogger

    /// Qwen3 hybrid-thinking models honor this template flag; Instruct-2507 ignores it.
    static let chatContext: [String: any Sendable] = ["enable_thinking": false]
    /// GPU buffer-cache cap so MLX does not hoard memory on a 16 GB machine (override: LOCALFLOW_GPU_CACHE_MB).
    public static var gpuCacheLimitBytes: Int {
        if let s = ProcessInfo.processInfo.environment["LOCALFLOW_GPU_CACHE_MB"], let mb = Int(s) { return mb * 1024 * 1024 }
        return 512 * 1024 * 1024
    }
    /// Reuse strategy for the prefix cache: trim in place when every layer cache supports it (Qwen3),
    /// otherwise deep-copy per request (Qwen3.5's Mamba caches). Override: LOCALFLOW_PREFIX_MODE=copy|trim.
    public private(set) var prefixMode = "trim"

    public init(modelID: String, directory: URL, logger: FlowLogger = .shared) {
        self.modelID = modelID
        self.directory = directory
        self.logger = logger
    }

    public var isLoaded: Bool { context != nil }
    public var prefixTokenCount: Int { prefixTokens.count }

    public func setPrefixCaching(_ enabled: Bool) {
        prefixCachingEnabled = enabled
    }

    /// Load weights + tokenizer from `directory`. Never touches the network.
    public func load() async throws {
        guard ModelManager.llmPresent(at: directory) else { throw BackendError.modelMissing(directory) }
        MLX.Memory.cacheLimit = Self.gpuCacheLimitBytes
        let t0 = Date()
        context = try await LLMModelFactory.shared.load(from: directory, using: TransformersTokenizerLoader())
        logger.info("llm loaded \(modelID) in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    }

    public func unload() {
        context = nil
        prefixCache = nil
        prefixTokens = []
        prefixSystem = nil
        MLX.Memory.clearCache()
    }

    /// Tokenize the full chat for a system + user pair.
    private func render(system: String, user: String) async throws -> [Int] {
        guard let context else { throw BackendError.notLoaded }
        let input = UserInput(chat: [.system(system), .user(user)], additionalContext: Self.chatContext)
        let lm = try await context.processor.prepare(input: input)
        return lm.text.tokens.asArray(Int.self)
    }

    /// Compute (or recompute) the KV cache for the static prefix of `system`.
    /// The prefix is the common token prefix of two renders with different user turns,
    /// so it ends exactly where the transcript starts. Returns the prefix length in tokens.
    @discardableResult
    public func prepare(system: String) async throws -> Int {
        guard let context else { throw BackendError.notLoaded }
        let t0 = Date()
        let r1 = try await render(system: system, user: CleanupPrompt.user(transcript: "a"))
        let r2 = try await render(system: system, user: CleanupPrompt.user(transcript: "zz zz zz zz"))
        var n = 0
        while n < min(r1.count, r2.count), r1[n] == r2[n] { n += 1 }
        let prefix = Array(r1[..<n])
        let cache = try context.model.newCache(parameters: baseParameters)
        _ = try TokenIterator(input: LMInput(tokens: MLXArray(prefix.map(Int32.init))),
                              model: context.model, cache: cache, parameters: baseParameters)
        eval(cache.flatMap { $0.state })
        prefixTokens = prefix
        prefixCache = cache
        prefixSystem = system
        logger.info("llm prefix cache built: \(n) tokens in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        return n
    }

    /// One dummy generation so the first real request does not pay for Metal kernel compilation.
    public func warmUp(system: String) async throws {
        _ = try await generate(system: system, user: CleanupPrompt.user(transcript: "um hello there"), maxTokensForInput: { _ in 8 })
    }

    public func generate(system: String, user: String, maxTokensForInput: @Sendable (Int) -> Int) async throws -> LLMOutput {
        guard let context else { throw BackendError.notLoaded }
        if prefixCachingEnabled, prefixCache == nil || prefixSystem != system {
            try await prepare(system: system)
        }
        let full = try await render(system: system, user: user)
        let userTokens = context.tokenizer.encode(text: user, addSpecialTokens: false).count
        var params = baseParameters
        params.maxTokens = max(8, maxTokensForInput(userTokens))

        var cache: [KVCache]? = nil
        var suffix = full
        var cached = 0
        var copyMs = 0.0
        var trimAfter = false
        if prefixCachingEnabled, let pc = prefixCache, full.count > prefixTokens.count, full.starts(with: prefixTokens) {
            let c0 = Date()
            let wantTrim = (ProcessInfo.processInfo.environment["LOCALFLOW_PREFIX_MODE"] ?? "trim") == "trim"
            if wantTrim, canTrimPromptCache(pc) {
                cache = pc                         // use in place; rewound to the prefix after generation
                trimAfter = true
                prefixMode = "trim"
            } else {
                cache = pc.map { $0.copy() }       // independent deep copy
                prefixMode = "copy"
            }
            copyMs = Date().timeIntervalSince(c0) * 1000
            suffix = Array(full[prefixTokens.count...])
            cached = prefixTokens.count
        }
        defer {
            if trimAfter, let pc = prefixCache {
                let extra = (pc.first?.offset ?? prefixTokens.count) - prefixTokens.count
                if extra > 0 { _ = trimPromptCache(pc, numTokens: extra) }
                if (pc.first?.offset ?? -1) != prefixTokens.count { prefixCache = nil }   // rebuild next time
            }
        }

        let t0 = Date()
        var text = ""
        var info: GenerateCompletionInfo?
        let stream = try MLXLMCommon.generate(input: LMInput(tokens: MLXArray(suffix.map(Int32.init))),
                                              cache: cache, parameters: params, context: context)
        for await event in stream {
            switch event {
            case .chunk(let s): text += s
            case .info(let i): info = i
            default: break
            }
        }
        let wallMs = Date().timeIntervalSince(t0) * 1000
        let prefillMs = (info.map { $0.promptTime * 1000 } ?? wallMs) + copyMs
        let generateMs = info.map { $0.generateTime * 1000 } ?? 0
        return LLMOutput(text: text,
                         promptTokens: full.count,
                         cachedPrefixTokens: cached,
                         generatedTokens: info?.generationTokenCount ?? 0,
                         prefillMs: prefillMs,
                         generateMs: generateMs)
    }
}
