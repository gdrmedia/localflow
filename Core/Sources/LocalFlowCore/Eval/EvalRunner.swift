import Foundation

public struct EvalCase: Codable, Sendable, Equatable {
    public var id: Int
    public var input: String
    public var expected: String
    public var tags: [String]?

    public init(id: Int, input: String, expected: String, tags: [String]? = nil) {
        self.id = id; self.input = input; self.expected = expected; self.tags = tags
    }

    public var mustPass: Bool { tags?.contains("must-pass") ?? false }
}

public struct EvalCaseResult: Sendable {
    public var caseID: Int
    public var input: String
    public var expected: String
    public var actual: String
    public var passed: Bool
    public var usedLLM: Bool
    public var fallbackReason: String?
    public var llmMs: Double
    public var mustPass: Bool
}

public struct EvalReport: Sendable {
    public var model: String
    public var results: [EvalCaseResult]
    public var passed: Int { results.filter(\.passed).count }
    public var total: Int { results.count }
    public var accuracy: Double { total == 0 ? 0 : Double(passed) / Double(total) }
    public var mustPassAllOK: Bool { results.filter(\.mustPass).allSatisfy(\.passed) }
    public var llmLatencies: [Double] { results.filter(\.usedLLM).map(\.llmMs) }
    public var p50: Double { EvalRunner.percentile(llmLatencies, 0.5) }
    public var p95: Double { EvalRunner.percentile(llmLatencies, 0.95) }
}

public enum EvalRunner {
    public static func loadCases(from url: URL) throws -> [EvalCase] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let dec = JSONDecoder()
        return try text.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
            return try dec.decode(EvalCase.self, from: Data(t.utf8))
        }
    }

    /// Case- and punctuation-insensitive: lowercase, keep letters/digits/newlines only.
    /// Spaces are dropped so "3:30 PM" == "3:30pm", but newline counts are preserved
    /// so a missing paragraph break still fails.
    public static func normalize(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if ch.isNewline { out.append("\n") }
            else if ch.isLetter || ch.isNumber { out.append(ch) }
        }
        return out.trimmingCharacters(in: .newlines)
    }

    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = p * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
        if lo == hi { return sorted[lo] }
        let frac = rank - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }

    public static func run(cases: [EvalCase], pipeline: CleanupPipeline, model: String,
                           progress: (@Sendable (EvalCaseResult) -> Void)? = nil) async -> EvalReport {
        var results: [EvalCaseResult] = []
        for c in cases {
            let r = await pipeline.clean(c.input)
            let passed = normalize(r.text) == normalize(c.expected)
            let res = EvalCaseResult(caseID: c.id, input: c.input, expected: c.expected, actual: r.text, passed: passed,
                                     usedLLM: r.usedLLM, fallbackReason: r.fallbackReason, llmMs: r.llmMs, mustPass: c.mustPass)
            progress?(res)
            results.append(res)
        }
        return EvalReport(model: model, results: results)
    }

    public static func markdownTable(_ reports: [EvalReport]) -> String {
        var s = "| Model | Accuracy | Must-pass (1/7/8/9/17) | LLM p50 | LLM p95 |\n|---|---|---|---|---|\n"
        for r in reports {
            s += String(format: "| %@ | %d/%d (%.0f%%) | %@ | %.0f ms | %.0f ms |\n",
                        r.model, r.passed, r.total, r.accuracy * 100, r.mustPassAllOK ? "all pass" : "FAIL", r.p50, r.p95)
        }
        return s
    }
}
