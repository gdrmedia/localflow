import Foundation

/// Inputs of `maxWords` words or fewer bypass the LLM and are normalized in code.
public enum ShortInput {
    public static let maxWords = 3

    static let fillers: Set<String> = ["um", "uh", "er", "ah", "hmm", "hm", "mm", "mhm", "eh", "este", "em", "ehm", "uhm", "umm"]

    public static func isShort(_ text: String) -> Bool {
        Guardrails.wordCount(text) <= maxWords
    }

    /// Returns "" when nothing meaningful remains (caller must not paste).
    public static func normalize(_ text: String, vocabulary: [String]) -> String {
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        let kept = tokens.filter { tok in
            let bare = tok.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return !fillers.contains(bare)
        }
        let joined = kept.joined(separator: " ")
        guard TextSanity.isMeaningful(joined) else { return "" }
        let withVocab = VocabularyNormalizer.apply(joined, vocabulary: vocabulary)
        return Guardrails.fallback(raw: withVocab)
    }
}

public enum TextSanity {
    /// True when the text contains at least one letter or digit (not empty, not just punctuation/noise).
    public static func isMeaningful(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}

/// Leading filler run ("um so like…", "este bueno…") removed in code before the LLM sees the text.
/// A dictation that *starts* with these words is never using them meaningfully.
public enum LeadingFillers {
    static let leading: Set<String> = ["um", "uh", "er", "ah", "hmm", "hm", "mm", "mhm", "eh", "ehm", "uhm", "umm", "so", "este", "bueno", "o sea"]

    public static func strip(_ text: String) -> String {
        var tokens = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        var removed = 0
        while tokens.count > 1 {
            let bare = tokens[0].lowercased().trimmingCharacters(in: .punctuationCharacters)
            guard leading.contains(bare) else { break }
            tokens.removeFirst()
            removed += 1
        }
        guard removed > 0 else { return text }
        return tokens.joined(separator: " ")
    }
}
