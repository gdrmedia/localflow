import Foundation

/// Splits long transcripts into ~`targetWords` chunks on sentence boundaries
/// so each LLM call stays small. Inputs at or under `thresholdWords` are returned whole.
public enum TextChunker {
    public static let defaultThreshold = 350
    public static let defaultTarget = 250

    public static func chunks(for text: String, thresholdWords: Int = defaultThreshold, targetWords: Int = defaultTarget) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard Guardrails.wordCount(trimmed) > thresholdWords else { return [trimmed] }

        var result: [String] = []
        var current: [String] = []
        var currentWords = 0

        func flush() {
            if !current.isEmpty {
                result.append(current.joined(separator: " "))
                current = []
                currentWords = 0
            }
        }

        for sentence in sentences(trimmed) {
            let n = Guardrails.wordCount(sentence)
            if n > targetWords * 2 {
                // A giant unpunctuated run: hard-split on word boundaries.
                flush()
                let words = sentence.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                var i = 0
                while i < words.count {
                    let slice = words[i..<min(i + targetWords, words.count)]
                    result.append(slice.joined(separator: " "))
                    i += targetWords
                }
                continue
            }
            if currentWords + n > targetWords && currentWords > 0 {
                flush()
            }
            current.append(sentence)
            currentWords += n
        }
        flush()
        return result
    }

    /// Split on sentence terminators (. ! ? …) and newlines, keeping the terminator with its sentence.
    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let scalars = Array(text)
        var i = 0
        while i < scalars.count {
            let ch = scalars[i]
            cur.append(ch)
            let isTerminator = ".!?…".contains(ch)
            let isNewline = ch.isNewline
            if isNewline {
                let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                cur = ""
            } else if isTerminator {
                // Lookahead: end of text or whitespace → sentence end. Avoids splitting "3.30" or "e.g."
                let next = i + 1 < scalars.count ? scalars[i + 1] : " "
                if next.isWhitespace {
                    let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { out.append(t) }
                    cur = ""
                }
            }
            i += 1
        }
        let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { out.append(t) }
        return out
    }

    /// Join cleaned chunks back together.
    public static func join(_ chunks: [String]) -> String {
        chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Spoken formatting commands. Handled in code, before the LLM: the transcript is split on
/// "new line" / "new paragraph", each segment is cleaned independently, and the segments are
/// joined with "\n" / "\n\n". Deterministic, and the model never has to reason about breaks.
public enum SpokenBreaks {
    public struct Segment: Equatable, Sendable {
        public var text: String
        /// Separator to place after this segment ("" for the last one).
        public var separatorAfter: String
        public init(text: String, separatorAfter: String) { self.text = text; self.separatorAfter = separatorAfter }
    }

    private static let pattern: NSRegularExpression = {
        // "new paragraph" / "new line" / Spanish "nuevo párrafo" / "nueva línea", surrounded by optional punctuation
        try! NSRegularExpression(pattern: "[\\s,.;:]*\\b(new\\s+paragraph|new\\s+line|nuevo\\s+p[aá]rrafo|nueva\\s+l[ií]nea)\\b[\\s,.;:]*",
                                 options: [.caseInsensitive])
    }()

    public static func containsBreak(_ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func split(_ text: String) -> [Segment] {
        let ns = text as NSString
        var segments: [Segment] = []
        var cursor = 0
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let command = ns.substring(with: m.range(at: 1)).lowercased()
            let sep = (command.contains("paragraph") || command.contains("rrafo")) ? "\n\n" : "\n"
            let t = before.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                segments.append(Segment(text: t, separatorAfter: sep))
            } else if var last = segments.popLast() {
                last.separatorAfter = sep.count > last.separatorAfter.count ? sep : last.separatorAfter
                segments.append(last)
            }
            cursor = m.range.location + m.range.length
        }
        let tail = ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { segments.append(Segment(text: tail, separatorAfter: "")) }
        if var last = segments.popLast() { last.separatorAfter = ""; segments.append(last) }
        return segments
    }

    public static func join(_ parts: [(text: String, separatorAfter: String)]) -> String {
        parts.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) + $0.separatorAfter }.joined()
    }
}
