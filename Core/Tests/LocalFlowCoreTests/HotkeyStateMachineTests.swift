import XCTest
import LocalFlowCore

final class HotkeyStateMachineTests: XCTestCase {
    typealias SM = HotkeyStateMachine

    func testPushToTalkHold() {
        var sm = SM()
        XCTAssertEqual(sm.handle(.hotkeyDown, at: 0).action, .startRecording)
        XCTAssertTrue(sm.isRecording)
        XCTAssertEqual(sm.handle(.hotkeyUp, at: 1.5).action, .stopAndProcess)
        XCTAssertFalse(sm.isRecording)
    }
    func testShortTapIsIgnored() {
        var sm = SM()
        XCTAssertEqual(sm.handle(.hotkeyDown, at: 0).action, .startRecording)
        XCTAssertEqual(sm.handle(.hotkeyUp, at: 0.1).action, .cancelRecording)
        XCTAssertEqual(sm.state, .idle)
    }
    func testExactly250msCountsAsHold() {
        var sm = SM()
        _ = sm.handle(.hotkeyDown, at: 10)
        XCTAssertEqual(sm.handle(.hotkeyUp, at: 10.25).action, .stopAndProcess)
    }
    func testDoubleTapStartsHandsFreeAndNextPressStops() {
        var sm = SM()
        _ = sm.handle(.hotkeyDown, at: 0)
        XCTAssertEqual(sm.handle(.hotkeyUp, at: 0.1).action, .cancelRecording)
        XCTAssertEqual(sm.handle(.hotkeyDown, at: 0.3).action, .startRecording)
        XCTAssertEqual(sm.state, .recordingHandsFree(since: 0.3))
        // release of the second tap is ignored
        XCTAssertEqual(sm.handle(.hotkeyUp, at: 0.4).action, .none)
        XCTAssertTrue(sm.isRecording)
        // keep talking… a single press stops
        XCTAssertEqual(sm.handle(.hotkeyDown, at: 8).action, .stopAndProcess)
        XCTAssertEqual(sm.handle(.hotkeyUp, at: 8.1).action, .none)
        XCTAssertEqual(sm.state, .idle)
    }
    func testTwoTapsOutsideWindowAreNotADoubleTap() {
        var sm = SM()
        _ = sm.handle(.hotkeyDown, at: 0)
        _ = sm.handle(.hotkeyUp, at: 0.1)
        XCTAssertEqual(sm.handle(.hotkeyDown, at: 0.5).action, .startRecording)
        XCTAssertEqual(sm.state, .recordingHeld(since: 0.5))
        XCTAssertEqual(sm.handle(.hotkeyUp, at: 0.6).action, .cancelRecording)
    }
    func testStoppingTapDoesNotSeedADoubleTap() {
        var sm = SM()
        _ = sm.handle(.hotkeyDown, at: 0); _ = sm.handle(.hotkeyUp, at: 0.1)
        _ = sm.handle(.hotkeyDown, at: 0.2); _ = sm.handle(.hotkeyUp, at: 0.3) // hands-free on
        _ = sm.handle(.hotkeyDown, at: 5); _ = sm.handle(.hotkeyUp, at: 5.05)  // stop
        XCTAssertEqual(sm.handle(.hotkeyDown, at: 5.2).action, .startRecording)
        XCTAssertEqual(sm.state, .recordingHeld(since: 5.2))
    }
    func testEscapeCancelsAndIsConsumedOnlyWhileRecording() {
        var sm = SM()
        let idle = sm.handle(.escape, at: 0)
        XCTAssertEqual(idle.action, .none)
        XCTAssertFalse(idle.consumeEvent)
        _ = sm.handle(.hotkeyDown, at: 1)
        let rec = sm.handle(.escape, at: 2)
        XCTAssertEqual(rec.action, .cancelRecording)
        XCTAssertTrue(rec.consumeEvent)
        XCTAssertEqual(sm.state, .idle)
        // the key-up that follows is ignored
        XCTAssertEqual(sm.handle(.hotkeyUp, at: 2.5).action, .none)
    }
    func testMaxDurationAutoStops() {
        var sm = SM(maxRecordingSeconds: 300)
        _ = sm.handle(.hotkeyDown, at: 0)
        XCTAssertEqual(sm.handle(.tick, at: 299).action, .none)
        XCTAssertEqual(sm.handle(.tick, at: 300).action, .stopAndProcess)
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(sm.handle(.hotkeyUp, at: 301).action, .none)
    }
    func testHotkeyUpInIdleIsIgnored() {
        var sm = SM()
        XCTAssertEqual(sm.handle(.hotkeyUp, at: 0).action, .none)
    }
    func testRepeatedDownWhileHeldIsIgnored() {
        var sm = SM()
        _ = sm.handle(.hotkeyDown, at: 0)
        XCTAssertEqual(sm.handle(.hotkeyDown, at: 0.5).action, .none)
        XCTAssertEqual(sm.state, .recordingHeld(since: 0))
    }
}
