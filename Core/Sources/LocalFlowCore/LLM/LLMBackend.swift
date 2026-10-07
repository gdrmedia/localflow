import Foundation

/// Output of one LLM generation.
public struct LLMOutput: Sendable, Equatable {
    public var text: String
    public var promptTokens: Int
    public var cachedPrefixTokens: Int
    public var generatedTokens: Int
    public var prefillMs: Double
    public var generateMs: Double
    public var totalMs: Double { prefillMs + generateMs }

    public init(text: String, promptTokens: Int = 0, cachedPrefixTokens: Int = 0, generatedTokens: Int = 0, prefillMs: Double = 0, generateMs: Double = 0) {
        self.text = text
        self.promptTokens = promptTokens
        self.cachedPrefixTokens = cachedPrefixTokens
        self.generatedTokens = generatedTokens
        self.prefillMs = prefillMs
        self.generateMs = generateMs
    }
}

/// Anything that can run the cleanup chat. The MLX implementation is `MLXCleanupBackend`;
/// tests use a scripted fake.
public protocol LLMBackend: Sendable {
    var modelID: String { get }
    /// Generate greedily for a system + user message. `maxTokensForInput` receives the
    /// number of tokens in the user turn so the caller's maxTokens rule can be applied.
    func generate(system: String, user: String, maxTokensForInput: @Sendable (Int) -> Int) async throws -> LLMOutput
}
