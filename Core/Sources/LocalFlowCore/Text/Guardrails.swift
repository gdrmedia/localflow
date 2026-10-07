import Foundation

/// Post-generation checks on the LLM output. On failure the caller pastes
/// `Guardrails.fallback(raw:)` instead of the model output.
public enum Guardrails {
    /// Phrases that indicate the model answered/explained instead of cleaning.
    /// A phrase only counts if it is absent from the input (so a dictated "Sure, let's do it" survives).
    public static let refusalPhrases = ["Here is", "Here's the", "Sure", "cleaned", "<think"]

    public static let maxRatio = 1.4
    public static let minRatio = 0.25

    /// English + Spanish correction markers. "scratch that" is the spec's explicit lower-bound exemption;
    /// the others are included because a genuine self-correction legitimately shrinks the text a lot.
    public static let correctionMarkers = [
        "scratch that", "no sorry", "sorry", "i meant", "i mean ", "actually", "wait", "no no",
        "no, perdón", "no perdón", "perdón", "digo", "mejor dicho", "o sea",
    ]

    public struct Verdict: Equatable, Sendable {
        public var passed: Bool
        public var reason: String?
        public static let ok = Verdict(passed: true, reason: nil)
        public static func fail(_ r: String) -> Verdict { Verdict(passed: false, reason: r) }
    }

    /// Remove `<think>…</think>` blocks (also an unclosed `<think>` to end of string).
    public static func stripThinking(_ text: String) -> String {
        var s = text
        // closed blocks (dot matches newlines)
        if let re = try? NSRegularExpression(pattern: "<think>.*?</think>", options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        // unclosed block
        if let r = s.range(of: "<think>", options: .caseInsensitive) {
            s = String(s[..<r.lowerBound])
        }
        // stray closing tag (model skipped the opening tag)
        if let r = s.range(of: "</think>", options: .caseInsensitive) {
            s = String(s[r.upperBound...])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    public static func containsScratchThat(_ text: String) -> Bool {
        text.lowercased().contains("scratch that")
    }

    public static func containsCorrectionMarker(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        return correctionMarkers.contains { lower.contains($0) }
    }

    /// Validate `output` against `input` (the raw transcript).
    public static func check(output: String, input: String) -> Verdict {
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { return .fail("empty output") }
        let lowerInput = input.lowercased()
        for phrase in refusalPhrases where out.contains(phrase) && !lowerInput.contains(phrase.lowercased()) {
            return .fail("refusal/meta phrase: \(phrase)")
        }
        let inWords = max(wordCount(input), 1)
        let outWords = wordCount(out)
        let ratio = Double(outWords) / Double(inWords)
        if ratio > maxRatio { return .fail(String(format: "too long: %.2fx", ratio)) }
        let exemptLower = containsScratchThat(input) || containsCorrectionMarker(input)
        if !exemptLower && ratio < minRatio { return .fail(String(format: "too short: %.2fx", ratio)) }
        return .ok
    }

    /// Minimal deterministic cleanup used when the LLM is off, fails, or is bypassed:
    /// trim, collapse whitespace, capitalize the first letter, add a trailing period.
    public static func fallback(raw: String) -> String {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard let first = collapsed.first else { return "" }
        var s = String(first).uppercased() + collapsed.dropFirst()
        if let last = s.last, !".!?…\"')".contains(last) {
            s += "."
        }
        return s
    }
}
