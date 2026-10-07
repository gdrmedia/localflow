import AVFoundation
import ApplicationServices
import CoreGraphics
import Foundation

/// The three TCC permissions LocalFlow needs, detected (not assumed) at launch and on every tick.
enum Permissions {
    struct Snapshot: Equatable {
        var microphone: Bool
        var accessibility: Bool
        var inputMonitoring: Bool
        var allGranted: Bool { microphone && accessibility && inputMonitoring }
        var missing: [String] {
            var m: [String] = []
            if !microphone { m.append("Microphone") }
            if !accessibility { m.append("Accessibility") }
            if !inputMonitoring { m.append("Input Monitoring") }
            return m
        }
    }

    static func snapshot() -> Snapshot {
        Snapshot(microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                 accessibility: AXIsProcessTrusted(),
                 inputMonitoring: CGPreflightListenEventAccess())
    }

    /// Trigger the system prompts. Each one appears at most once per app install.
    static func requestAll() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
    }
}
