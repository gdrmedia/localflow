import XCTest
import LocalFlowCore

final class DictationHistoryTests: XCTestCase {
    private func store() -> DictationHistory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localflow-history-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.jsonl")
        return DictationHistory(url: url)
    }

    func testAppendLoadNewestFirst() {
        let h = store()
        h.append(HistoryEntry(ts: Date(timeIntervalSince1970: 1), raw: "um first", cleaned: "First.", seconds: 1.5, app: "Notes", pasted: true, usedLLM: true))
        h.append(HistoryEntry(ts: Date(timeIntervalSince1970: 2), raw: "second", cleaned: "Second."))
        let all = h.load()
        XCTAssertEqual(all.map(\.cleaned), ["Second.", "First."])
        XCTAssertEqual(all[1].app, "Notes")
        XCTAssertEqual(all[1].pasted, true)
        XCTAssertEqual(all[1].seconds, 1.5)
    }
    func testDeleteAndClear() {
        let h = store()
        let a = HistoryEntry(raw: "a", cleaned: "A."), b = HistoryEntry(raw: "b", cleaned: "B.")
        h.append(a); h.append(b)
        h.delete(id: a.id)
        XCTAssertEqual(h.load().map(\.id), [b.id])
        h.clear()
        XCTAssertEqual(h.load(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.url.path))
    }
    func testOldFormatAndMalformedLinesAreTolerated() throws {
        let h = store()
        try FileManager.default.createDirectory(at: h.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {"ts":"2026-10-06T23:00:00Z","raw":"old line","cleaned":"Old line."}
        not json at all
        {"id":"B3A1C2D4-0000-0000-0000-000000000000","ts":"2026-10-06T23:30:00.000Z","raw":"new","cleaned":"New.","pasted":false}

        """.utf8).write(to: h.url)
        let all = h.load()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].cleaned, "New.")
        XCTAssertEqual(all[0].id.uuidString, "B3A1C2D4-0000-0000-0000-000000000000")
        XCTAssertEqual(all[1].cleaned, "Old line.")
        XCTAssertEqual(Int(all[1].ts.timeIntervalSince1970), 1791327600)
    }
    func testRoundTripPreservesIDsAndDates() {
        let h = store()
        let e = HistoryEntry(ts: Date(timeIntervalSince1970: 1_700_000_000.25), raw: "r", cleaned: "C.")
        h.append(e)
        let back = h.load().first!
        XCTAssertEqual(back.id, e.id)
        XCTAssertEqual(back.ts.timeIntervalSince1970, 1_700_000_000.25, accuracy: 0.001)
    }
}
