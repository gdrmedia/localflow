import XCTest
import LocalFlowCore

final class VocabularyTests: XCTestCase {
    let vocab = AppConfig.defaultVocabulary

    func testSplitBrandNames() {
        XCTAssertEqual(VocabularyNormalizer.apply("can you check the hub spot web flow site", vocabulary: vocab),
                       "can you check the HubSpot Webflow site")
    }
    func testCaseOnly() {
        XCTAssertEqual(VocabularyNormalizer.apply("open figma and notion", vocabulary: vocab), "open Figma and Notion")
    }
    func testMultiWordTerm() {
        XCTAssertEqual(VocabularyNormalizer.apply("the google docs invoice", vocabulary: vocab), "the Google Docs invoice")
    }
    func testDoesNotTouchSubstrings() {
        XCTAssertEqual(VocabularyNormalizer.apply("notional and the market opened", vocabulary: vocab),
                       "notional and the market opened")
    }
    func testPossessiveKept() {
        XCTAssertEqual(VocabularyNormalizer.apply("figma's birthday", vocabulary: vocab), "Figma's birthday")
    }
}
