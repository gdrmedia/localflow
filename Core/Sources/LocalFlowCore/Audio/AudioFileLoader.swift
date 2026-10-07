import Foundation
import AVFoundation
import FluidAudio

/// Loads any audio file AVFoundation can read and converts it to 16 kHz mono Float32.
public enum AudioFileLoader {
    public static func load(_ url: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(url)
    }

    /// Root-mean-square level in linear scale (0…1).
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var acc: Float = 0
        for s in samples { acc += s * s }
        return (acc / Float(samples.count)).squareRoot()
    }

    public static func dBFS(_ samples: [Float]) -> Float {
        let r = rms(samples)
        return r > 0 ? 20 * log10(r) : -120
    }
}

/// Silence guard: skip processing when the recording is effectively silent.
public enum SilenceGuard {
    /// Speech sits around -20…-35 dBFS; room noise is below -55 dBFS.
    public static let thresholdDBFS: Float = -50
    public static func isSilent(_ samples: [Float]) -> Bool {
        AudioFileLoader.dBFS(samples) < thresholdDBFS
    }
}
