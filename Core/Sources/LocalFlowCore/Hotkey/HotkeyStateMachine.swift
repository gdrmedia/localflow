import Foundation

/// Pure-logic hotkey state machine. No keyboard, no timers: the caller feeds
/// events with timestamps (seconds) and performs the returned action.
///
/// Rules (from the spec):
/// - Push-to-talk: recording starts on press, stops on release.
/// - Presses shorter than `minHoldSeconds` are taps; a lone tap discards the recording.
/// - Two taps within `doubleTapWindow` (press-to-press) start hands-free recording;
///   the next press stops it.
/// - Esc while recording cancels (and is consumed). Esc when idle passes through.
/// - `maxRecordingSeconds` auto-stops and processes.
public struct HotkeyStateMachine: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// Hotkey is held; recording started at `since`.
        case recordingHeld(since: TimeInterval)
        /// Hands-free mode; recording started at `since`.
        case recordingHandsFree(since: TimeInterval)
    }

    public enum Event: Equatable, Sendable {
        case hotkeyDown
        case hotkeyUp
        case escape
        /// Periodic clock tick, used for the max-duration cap.
        case tick
    }

    public enum Action: Equatable, Sendable {
        case none
        case startRecording
        case stopAndProcess
        case cancelRecording
    }

    public struct Output: Equatable, Sendable {
        public var action: Action
        /// true when the originating key event should be swallowed (not passed to the frontmost app)
        public var consumeEvent: Bool
        public init(_ action: Action, consume: Bool) { self.action = action; self.consumeEvent = consume }
    }

    public private(set) var state: State = .idle
    public var minHoldSeconds: TimeInterval
    public var doubleTapWindow: TimeInterval
    public var maxRecordingSeconds: TimeInterval
    private var lastTapDown: TimeInterval?

    public init(minHoldSeconds: TimeInterval = 0.25, doubleTapWindow: TimeInterval = 0.35, maxRecordingSeconds: TimeInterval = 300) {
        self.minHoldSeconds = minHoldSeconds
        self.doubleTapWindow = doubleTapWindow
        self.maxRecordingSeconds = maxRecordingSeconds
    }

    public var isRecording: Bool {
        if case .idle = state { return false }
        return true
    }

    public var recordingStart: TimeInterval? {
        switch state {
        case .idle: return nil
        case .recordingHeld(let s), .recordingHandsFree(let s): return s
        }
    }

    public mutating func handle(_ event: Event, at t: TimeInterval) -> Output {
        switch (state, event) {
        // MARK: idle
        case (.idle, .hotkeyDown):
            if let last = lastTapDown, t - last <= doubleTapWindow, t >= last {
                lastTapDown = nil
                state = .recordingHandsFree(since: t)
            } else {
                state = .recordingHeld(since: t)
            }
            return Output(.startRecording, consume: true)
        case (.idle, .hotkeyUp), (.idle, .tick):
            return Output(.none, consume: false)
        case (.idle, .escape):
            return Output(.none, consume: false)

        // MARK: held (push-to-talk or first tap)
        case (.recordingHeld(let since), .hotkeyUp):
            let held = t - since
            state = .idle
            if held >= minHoldSeconds {
                lastTapDown = nil
                return Output(.stopAndProcess, consume: true)
            } else {
                lastTapDown = since
                return Output(.cancelRecording, consume: true)
            }
        case (.recordingHeld, .hotkeyDown):
            return Output(.none, consume: true)

        // MARK: hands-free
        case (.recordingHandsFree, .hotkeyDown):
            state = .idle
            lastTapDown = nil
            return Output(.stopAndProcess, consume: true)
        case (.recordingHandsFree, .hotkeyUp):
            // Release of the second tap of the double-tap, or of the stopping tap: ignored.
            return Output(.none, consume: true)

        // MARK: any recording
        case (.recordingHeld, .escape), (.recordingHandsFree, .escape):
            state = .idle
            lastTapDown = nil
            return Output(.cancelRecording, consume: true)
        case (.recordingHeld(let since), .tick), (.recordingHandsFree(let since), .tick):
            if t - since >= maxRecordingSeconds {
                state = .idle
                lastTapDown = nil
                return Output(.stopAndProcess, consume: false)
            }
            return Output(.none, consume: false)
        }
    }

    /// Force back to idle (e.g. when recording fails to start).
    public mutating func reset() {
        state = .idle
        lastTapDown = nil
    }
}
