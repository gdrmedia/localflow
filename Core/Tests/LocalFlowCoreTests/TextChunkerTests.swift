import XCTest
import LocalFlowCore

final class TextChunkerTests: XCTestCase {
    func testShortTextIsOneChunk() {
        XCTAssertEqual(TextChunker.chunks(for: "Hello there. How are you?"), ["Hello there. How are you?"])
    }
    func testEmpty() {
        XCTAssertEqual(TextChunker.chunks(for: "   "), [])
    }
    func testLongTextSplitsOnSentencesAndKeepsAllWords() {
        let sentence = "this is a ten word sentence that we repeat often ok."
        let text = Array(repeating: sentence, count: 80).joined(separator: " ")
        let totalWords = Guardrails.wordCount(text)
        let chunks = TextChunker.chunks(for: text)
        XCTAssertGreaterThan(chunks.count, 2)
        for c in chunks {
            XCTAssertLessThanOrEqual(Guardrails.wordCount(c), 260)
            XCTAssertTrue(c.hasSuffix("ok."), "chunk should end on a sentence boundary: \(c.suffix(20))")
        }
        XCTAssertEqual(Guardrails.wordCount(TextChunker.join(chunks)), totalWords)
    }
    func testUnpunctuatedRunIsHardSplit() {
        let text = Array(repeating: "word", count: 700).joined(separator: " ")
        let chunks = TextChunker.chunks(for: text)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(Guardrails.wordCount(TextChunker.join(chunks)), 700)
    }
    func testDecimalNotSplit() {
        XCTAssertEqual(TextChunker.sentences("It costs 3.50 today. Fine."), ["It costs 3.50 today.", "Fine."])
    }
}

final class SpokenBreaksTests: XCTestCase {
    func testParagraph() {
        let segs = SpokenBreaks.split("first point new paragraph second point")
        XCTAssertEqual(segs, [.init(text: "first point", separatorAfter: "\n\n"), .init(text: "second point", separatorAfter: "")])
    }
    func testLineAndPunctuation() {
        let segs = SpokenBreaks.split("First item, new line. Second item new line third")
        XCTAssertEqual(segs.map(\.text), ["First item", "Second item", "third"])
        XCTAssertEqual(segs.map(\.separatorAfter), ["\n", "\n", ""])
    }
    func testNoBreak() {
        XCTAssertFalse(SpokenBreaks.containsBreak("a brand new lineup"))
        XCTAssertTrue(SpokenBreaks.containsBreak("the new line of products")) // known limitation: treated as a command
    }
    func testJoin() {
        XCTAssertEqual(SpokenBreaks.join([("First point.", "\n\n"), ("Second point.", "")]), "First point.\n\nSecond point.")
    }
}
