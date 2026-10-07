import XCTest
import LocalFlowCore

final class GuardrailsTests: XCTestCase {
    func testStripThinkingClosedBlock() {
        XCTAssertEqual(Guardrails.stripThinking("<think>\nreasoning here\n</think>\nI fell off the car."), "I fell off the car.")
    }
    func testStripThinkingUnclosedBlock() {
        XCTAssertEqual(Guardrails.stripThinking("I think.<think>never ends"), "I think.")
    }
    func testStripThinkingStrayClosingTag() {
        XCTAssertEqual(Guardrails.stripThinking("some reasoning</think>Send it to Dan."), "Send it to Dan.")
    }
    func testStripThinkingNoop() {
        XCTAssertEqual(Guardrails.stripThinking("  Plain text.  "), "Plain text.")
    }
    func testRefusalPhraseFails() {
        let v = Guardrails.check(output: "Here is the cleaned text: hello", input: "hello there")
        XCTAssertFalse(v.passed)
    }
    func testRefusalPhrasePresentInInputIsAllowed() {
        let v = Guardrails.check(output: "Sure, let's do it.", input: "sure let's do it")
        XCTAssertTrue(v.passed, v.reason ?? "")
    }
    func testTooLongFails() {
        let v = Guardrails.check(output: "one two three four five six seven eight", input: "one two three four")
        XCTAssertFalse(v.passed)
    }
    func testTooShortFails() {
        let v = Guardrails.check(output: "ok", input: "one two three four five six seven eight nine ten")
        XCTAssertFalse(v.passed)
    }
    func testTooShortExemptWithScratchThat() {
        let v = Guardrails.check(output: "Ship Monday.", input: "let's ship on Friday and tell everyone scratch that ship Monday")
        XCTAssertTrue(v.passed, v.reason ?? "")
    }
    func testEmptyFails() {
        XCTAssertFalse(Guardrails.check(output: "  \n", input: "hello").passed)
    }
    func testNormalPasses() {
        XCTAssertTrue(Guardrails.check(output: "I think we should push the meeting to Thursday.",
                                       input: "um so like I think we should uh push the meeting to Thursday").passed)
    }
    func testFallbackCapitalizesAndAddsPeriod() {
        XCTAssertEqual(Guardrails.fallback(raw: "  i fell  off the horse "), "I fell off the horse.")
        XCTAssertEqual(Guardrails.fallback(raw: "done?"), "Done?")
        XCTAssertEqual(Guardrails.fallback(raw: ""), "")
    }
}
