import Foundation

/// Deterministic preferred-spelling pass. For each term, matches the term's characters
/// case-insensitively with optional spaces/hyphens between them, bounded by non-alphanumerics,
/// and replaces with the canonical spelling ("hub spot" → "HubSpot", "web flow" → "Webflow").
public enum VocabularyNormalizer {
    public static func apply(_ text: String, vocabulary: [String]) -> String {
        var s = text
        for term in vocabulary {
            let trimmed = term.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3, let re = regex(for: trimmed) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                            withTemplate: NSRegularExpression.escapedTemplate(for: trimmed))
        }
        return s
    }

    static func regex(for term: String) -> NSRegularExpression? {
        let chars = term.filter { !$0.isWhitespace && $0 != "-" }
        let body = chars.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s\\-]*")
        let pattern = "(?<![\\p{L}\\p{N}])" + body + "(?![\\p{L}\\p{N}])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
