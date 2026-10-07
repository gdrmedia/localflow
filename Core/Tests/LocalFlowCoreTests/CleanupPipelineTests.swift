import XCTest
import LocalFlowCore

/// Scripted backend: returns canned outputs in order, or throws.
struct FakeBackend: LLMBackend {
    var modelID = "fake"
    var outputs: [String]
    var error: Error?
    let calls = Counter()
    final class Counter: @unchecked Sendable { var n = 0; var lastSystem = ""; var lastUser = "" }

    func generate(system: String, user: String, maxTokensForInput: @Sendable (Int) -> Int) async throws -> LLMOutput {
        calls.n += 1; calls.lastSystem = system; calls.lastUser = user
        if let error { throw error }
        let idx = min(calls.n - 1, outputs.count - 1)
        return LLMOutput(text: outputs[idx], promptTokens: 10, cachedPrefixTokens: 5, generatedTokens: 3, prefillMs: 1, generateMs: 2)
    }
}

final class CleanupPipelineTests: XCTestCase {
    let vocab = AppConfig.defaultVocabulary

    func testShortInputBypassesLLM() async {
        let be = FakeBackend(outputs: ["SHOULD NOT BE USED"])
        let p = CleanupPipeline(backend: be, vocabulary: vocab)
        let r = await p.clean("um yes please")
        XCTAssertEqual(r.text, "Yes please.")
        XCTAssertFalse(r.usedLLM)
        XCTAssertEqual(be.calls.n, 0)
    }
    func testEmptyNeverPastes() async {
        let p = CleanupPipeline(backend: FakeBackend(outputs: ["x"]), vocabulary: vocab)
        let dots = await p.clean("  ... ")
        let empty = await p.clean("")
        XCTAssertEqual(dots.text, "")
        XCTAssertEqual(empty.text, "")
    }
    func testLLMOutputPassesGuardrailsAndThinkIsStripped() async {
        let be = FakeBackend(outputs: ["<think>hmm</think>\nI fell off the car."])
        let p = CleanupPipeline(backend: be, vocabulary: vocab)
        let r = await p.clean("I fell off the horse no sorry I meant I fell off the car")
        XCTAssertEqual(r.text, "I fell off the car.")
        XCTAssertTrue(r.usedLLM)
        XCTAssertNil(r.fallbackReason)
        XCTAssertTrue(be.calls.lastUser.hasPrefix("<transcript>"))
        XCTAssertTrue(be.calls.lastSystem.contains("HubSpot"))
    }
    func testGuardrailFailureFallsBackToRaw() async {
        let be = FakeBackend(outputs: ["Here is the cleaned text: hello world"])
        let p = CleanupPipeline(backend: be, vocabulary: vocab)
        let r = await p.clean("hello world how are you doing today")
        XCTAssertEqual(r.text, "Hello world how are you doing today.")
        XCTAssertNotNil(r.fallbackReason)
    }
    func testBackendErrorFallsBackToRaw() async {
        struct Boom: Error {}
        let be = FakeBackend(outputs: [], error: Boom())
        let p = CleanupPipeline(backend: be, vocabulary: vocab)
        let r = await p.clean("check the hub spot site please now")
        XCTAssertEqual(r.text, "Check the HubSpot site please now.")
        XCTAssertTrue(r.fallbackReason?.contains("llm error") ?? false)
    }
    func testCleanupDisabledUsesDeterministic() async {
        let be = FakeBackend(outputs: ["nope"])
        let p = CleanupPipeline(backend: be, vocabulary: vocab, cleanupEnabled: false)
        let r = await p.clean("send it to figma tonight please")
        XCTAssertEqual(r.text, "Send it to Figma tonight please.")
        XCTAssertEqual(be.calls.n, 0)
    }
    func testLongInputIsChunkedAndJoined() async {
        let sentence = "we should ship the thing on friday for sure ok."
        let raw = Array(repeating: sentence, count: 60).joined(separator: " ") // 600 words → 3 chunks
        let be = FakeBackend(outputs: ["Chunk one.", "Chunk two.", "Chunk three."])
        let p = CleanupPipeline(backend: be, vocabulary: vocab)
        let r = await p.clean(raw)
        XCTAssertEqual(r.chunks, 3)
        XCTAssertEqual(be.calls.n, 3)
        // each canned output is far shorter than its chunk → guardrail "too short" → fallback per chunk
        XCTAssertNotNil(r.fallbackReason)
        XCTAssertEqual(Guardrails.wordCount(r.text), 600)
    }
    func testVocabularyPostPass() async {
        let be = FakeBackend(outputs: ["Can you check the hub spot web flow site?"])
        let p = CleanupPipeline(backend: be, vocabulary: vocab)
        let r = await p.clean("can you check the hub spot web flow site")
        XCTAssertEqual(r.text, "Can you check the HubSpot Webflow site?")
    }
    func testPostProcessStripsEchoedTagsAndQuotes() {
        XCTAssertEqual(CleanupPipeline.postProcess("\"Send it to Dan.\""), "Send it to Dan.")
        XCTAssertEqual(CleanupPipeline.postProcess("<transcript>Send it to Dan.</transcript>"), "Send it to Dan.")
        XCTAssertEqual(CleanupPipeline.postProcess("Output: Send it."), "Send it.")
    }
    func testMaxTokensRule() {
        XCTAssertEqual(CleanupPrompt.maxTokens(forInputTokens: 10), 84)
        XCTAssertEqual(CleanupPrompt.maxTokens(forInputTokens: 5000), 2048)
    }
}

final class EvalRunnerTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(EvalRunner.normalize("I'll call you at 3:30 PM."), EvalRunner.normalize("ill call you at 3:30pm"))
        XCTAssertNotEqual(EvalRunner.normalize("First point.\n\nSecond point."), EvalRunner.normalize("First point. Second point."))
        XCTAssertEqual(EvalRunner.normalize("First point.\n\nSecond point."), "firstpoint\n\nsecondpoint")
    }
    func testPercentile() {
        XCTAssertEqual(EvalRunner.percentile([10, 20, 30, 40], 0.5), 25)
        XCTAssertEqual(EvalRunner.percentile([10], 0.95), 10)
        XCTAssertEqual(EvalRunner.percentile([], 0.5), 0)
    }
    func testLoadCasesFromProjectFile() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../eval/cases.jsonl").standardized
        let cases = try EvalRunner.loadCases(from: url)
        XCTAssertGreaterThanOrEqual(cases.count, 27)
        XCTAssertEqual(cases.first?.id, 1)
        XCTAssertEqual(cases.filter(\.mustPass).map(\.id), [1, 7, 8, 9, 17])
    }
}

final class CleanupPipelineBreakTests: XCTestCase {
    func testSpokenParagraphIsSplitCleanedAndJoined() async {
        let be = FakeBackend(outputs: ["Please review the attached draft.", "Let me know by Friday."])
        let p = CleanupPipeline(backend: be, vocabulary: [])
        let r = await p.clean("um please review the attached draft new paragraph let me know by uh Friday")
        XCTAssertEqual(r.text, "Please review the attached draft.\n\nLet me know by Friday.")
        XCTAssertEqual(be.calls.n, 2)
    }
    func testShortSegmentsUseCodePath() async {
        let p = CleanupPipeline(backend: FakeBackend(outputs: ["x"]), vocabulary: [])
        let r = await p.clean("first point new paragraph second point")
        XCTAssertEqual(r.text, "First point.\n\nSecond point.")
        XCTAssertFalse(r.usedLLM)
    }
}
