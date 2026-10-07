import XCTest
import LocalFlowCore

final class ShortInputTests: XCTestCase {
    let vocab = AppConfig.defaultVocabulary

    func testIsShort() {
        XCTAssertTrue(ShortInput.isShort("yes"))
        XCTAssertTrue(ShortInput.isShort("sounds good to"))
        XCTAssertFalse(ShortInput.isShort("one two three four"))
    }
    func testNormalizeDropsFillersAndCapitalizes() {
        XCTAssertEqual(ShortInput.normalize("um yes", vocabulary: vocab), "Yes.")
    }
    func testNormalizeAppliesVocabulary() {
        XCTAssertEqual(ShortInput.normalize("check hub spot", vocabulary: vocab), "Check HubSpot.")
    }
    func testNormalizeOnlyFillersReturnsEmpty() {
        XCTAssertEqual(ShortInput.normalize("um uh", vocabulary: vocab), "")
    }
    func testPunctuationOnlyIsNotMeaningful() {
        XCTAssertFalse(TextSanity.isMeaningful("... ,"))
        XCTAssertTrue(TextSanity.isMeaningful("a"))
    }
}

final class LeadingFillersTests: XCTestCase {
    func testStripsLeadingRun() {
        XCTAssertEqual(LeadingFillers.strip("um so like I think we should go"), "like I think we should go")
        XCTAssertEqual(LeadingFillers.strip("So, um, basically we're done."), "basically we're done.")
        XCTAssertEqual(LeadingFillers.strip("este bueno te mando el archivo"), "te mando el archivo")
    }
    func testKeepsMeaningfulStarts() {
        XCTAssertEqual(LeadingFillers.strip("no I don't think so"), "no I don't think so")
        XCTAssertEqual(LeadingFillers.strip("like I said before"), "like I said before")
    }
    func testNeverEmptiesText() {
        XCTAssertEqual(LeadingFillers.strip("so"), "so")
    }
}
