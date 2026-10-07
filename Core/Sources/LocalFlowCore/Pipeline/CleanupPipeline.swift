import Foundation

/// Result of cleaning one transcript.
public struct CleanupResult: Sendable, Equatable {
    public var text: String
    public var raw: String
    public var usedLLM: Bool
    /// Set when the LLM output was rejected and the deterministic fallback was pasted instead.
    public var fallbackReason: String?
    public var chunks: Int
    public var llmMs: Double
    public var promptTokens: Int
    public var cachedPrefixTokens: Int
    public var generatedTokens: Int

    public init(text: String, raw: String, usedLLM: Bool, fallbackReason: String? = nil, chunks: Int = 0,
                llmMs: Double = 0, promptTokens: Int = 0, cachedPrefixTokens: Int = 0, generatedTokens: Int = 0) {
        self.text = text; self.raw = raw; self.usedLLM = usedLLM; self.fallbackReason = fallbackReason
        self.chunks = chunks; self.llmMs = llmMs; self.promptTokens = promptTokens
        self.cachedPrefixTokens = cachedPrefixTokens; self.generatedTokens = generatedTokens
    }
}

/// Short-input bypass → chunking → LLM → think-strip → guardrails → vocabulary → fallback.
/// Pure orchestration; the model lives behind `LLMBackend`.
public struct CleanupPipeline: Sendable {
    public var backend: LLMBackend?
    public var vocabulary: [String]
    public var cleanupEnabled: Bool

    public init(backend: LLMBackend?, vocabulary: [String], cleanupEnabled: Bool = true) {
        self.backend = backend
        self.vocabulary = vocabulary
        self.cleanupEnabled = cleanupEnabled
    }

    public var systemPrompt: String { CleanupPrompt.system(vocabulary: vocabulary) }

    /// Returns "" in `text` when there is nothing worth pasting.
    public func clean(_ rawInput: String) async -> CleanupResult {
        let raw = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TextSanity.isMeaningful(raw) else {
            return CleanupResult(text: "", raw: raw, usedLLM: false, fallbackReason: "empty or punctuation-only")
        }
        if ShortInput.isShort(raw) {
            return CleanupResult(text: ShortInput.normalize(raw, vocabulary: vocabulary), raw: raw, usedLLM: false)
        }
        // Spoken "new line" / "new paragraph": split, clean each segment, join with the right break.
        if SpokenBreaks.containsBreak(raw) {
            let segments = SpokenBreaks.split(raw)
            if segments.count > 1 || (segments.first.map { $0.text != raw } ?? false) {
                var parts: [(text: String, separatorAfter: String)] = []
                var merged = CleanupResult(text: "", raw: raw, usedLLM: false)
                for seg in segments {
                    let r = await clean(seg.text)
                    parts.append((r.text, seg.separatorAfter))
                    merged.usedLLM = merged.usedLLM || r.usedLLM
                    merged.fallbackReason = merged.fallbackReason ?? r.fallbackReason
                    merged.chunks += r.chunks; merged.llmMs += r.llmMs; merged.promptTokens += r.promptTokens
                    merged.cachedPrefixTokens += r.cachedPrefixTokens; merged.generatedTokens += r.generatedTokens
                }
                merged.text = SpokenBreaks.join(parts)
                return merged
            }
        }

        guard cleanupEnabled, let backend else {
            return CleanupResult(text: deterministic(raw), raw: raw, usedLLM: false)
        }

        let chunks = TextChunker.chunks(for: LeadingFillers.strip(raw))
        var outputs: [String] = []
        var llmMs = 0.0, promptTokens = 0, cached = 0, generated = 0
        var fallbackReason: String?

        for chunk in chunks {
            do {
                let out = try await backend.generate(system: systemPrompt,
                                                     user: CleanupPrompt.user(transcript: chunk),
                                                     maxTokensForInput: { CleanupPrompt.maxTokens(forInputTokens: $0) })
                llmMs += out.totalMs; promptTokens += out.promptTokens
                cached += out.cachedPrefixTokens; generated += out.generatedTokens
                let stripped = Self.postProcess(Guardrails.stripThinking(out.text))
                let verdict = Guardrails.check(output: stripped, input: chunk)
                if verdict.passed {
                    outputs.append(VocabularyNormalizer.apply(stripped, vocabulary: vocabulary))
                } else {
                    fallbackReason = verdict.reason
                    outputs.append(deterministic(chunk))
                }
            } catch {
                fallbackReason = "llm error: \(error.localizedDescription)"
                outputs.append(deterministic(chunk))
            }
        }
        let joined = TextChunker.join(outputs)
        return CleanupResult(text: joined, raw: raw, usedLLM: true, fallbackReason: fallbackReason, chunks: chunks.count,
                             llmMs: llmMs, promptTokens: promptTokens, cachedPrefixTokens: cached, generatedTokens: generated)
    }

    /// The fallback: raw transcript with vocabulary spellings, capitalization and a trailing period.
    public func deterministic(_ text: String) -> String {
        Guardrails.fallback(raw: VocabularyNormalizer.apply(text, vocabulary: vocabulary))
    }

    /// Strip a stray `<transcript>` echo, surrounding quotes, and leading "Output:" labels the model may add.
    public static func postProcess(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in [CleanupPrompt.transcriptOpen, CleanupPrompt.transcriptClose] {
            s = s.replacingOccurrences(of: tag, with: "")
        }
        for label in ["Cleaned text:", "Output:", "Cleaned:"] where s.hasPrefix(label) {
            s = String(s.dropFirst(label.count))
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            let inner = s.dropFirst().dropLast()
            if !inner.contains("\"") { s = String(inner) }
        }
        return s
    }
}
