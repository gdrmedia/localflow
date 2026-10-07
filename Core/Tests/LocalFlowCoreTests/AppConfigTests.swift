import XCTest
import LocalFlowCore

final class AppConfigTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("localflow-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    func testMissingFileCreatesDefaults() throws {
        let url = tempURL()
        let r = AppConfigStore(url: url).load()
        XCTAssertTrue(r.created)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.config, .default)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"hotkey\" : \"right_option\""))
        XCTAssertTrue(text.contains("HubSpot"))
    }
    func testPartialFileFillsDefaults() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"hotkey":"fn","historyEnabled":true}"#.utf8).write(to: url)
        let r = AppConfigStore(url: url).load()
        XCTAssertFalse(r.created)
        XCTAssertEqual(r.config.hotkey, .fn)
        XCTAssertTrue(r.config.historyEnabled)
        XCTAssertTrue(r.config.cleanupEnabled)
        XCTAssertEqual(r.config.llmModel, AppConfig.defaultLLMModel)
        XCTAssertEqual(r.config.vocabulary, AppConfig.defaultVocabulary)
    }
    func testInvalidValuesFallBackPerKey() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"hotkey":"banana","maxRecordingSeconds":"soon","cleanupEnabled":false}"#.utf8).write(to: url)
        let r = AppConfigStore(url: url).load()
        XCTAssertEqual(r.config.hotkey, .rightOption)
        XCTAssertEqual(r.config.maxRecordingSeconds, 300)
        XCTAssertFalse(r.config.cleanupEnabled)
    }
    func testMalformedJSONUsesDefaultsAndReportsError() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        let r = AppConfigStore(url: url).load()
        XCTAssertNotNil(r.error)
        XCTAssertEqual(r.config, .default)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{not json", "malformed file must be left untouched")
    }
    func testClampSeconds() {
        XCTAssertEqual(AppConfig.clampSeconds(0), 1)
        XCTAssertEqual(AppConfig.clampSeconds(99999), 3600)
    }
    func testRoundTrip() throws {
        let url = tempURL()
        var cfg = AppConfig.default
        cfg.vocabulary = ["Foo", "Bar"]
        cfg.pasteRawTranscript = true
        try AppConfigStore(url: url).save(cfg)
        XCTAssertEqual(AppConfigStore(url: url).load().config, cfg)
    }
}
