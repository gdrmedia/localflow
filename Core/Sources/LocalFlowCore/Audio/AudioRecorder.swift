import Foundation
import AVFoundation
import FluidAudio

/// Microphone capture with AVAudioEngine. Produces 16 kHz mono Float32 samples.
/// Uses the current default input device at `start()`; rebuilds the engine when
/// the configuration changes (AirPods connect, device switch).
public final class AudioRecorder: @unchecked Sendable {
    public enum RecorderError: Error, LocalizedError {
        case noInput
        case alreadyRecording
        public var errorDescription: String? {
            switch self {
            case .noInput: return "No audio input device"
            case .alreadyRecording: return "Already recording"
            }
        }
    }

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var converter: AudioConverter?
    private var samples: [Float] = []
    private var isRecording = false
    private var configObserver: NSObjectProtocol?
    private let logger: FlowLogger

    public init(logger: FlowLogger = .shared) {
        self.logger = logger
    }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
    }

    public var recording: Bool {
        lock.lock(); defer { lock.unlock() }
        return isRecording
    }

    /// Seconds captured so far.
    public var capturedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / Double(Transcriber.sampleRate)
    }

    public func start() throws {
        lock.lock()
        if isRecording { lock.unlock(); throw RecorderError.alreadyRecording }
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Transcriber.sampleRate * 60)
        isRecording = true
        lock.unlock()
        try buildAndStartEngine()
    }

    /// Stops capture and returns everything recorded since `start()`.
    @discardableResult
    public func stop() -> [Float] {
        tearDownEngine()
        lock.lock(); defer { lock.unlock() }
        isRecording = false
        let out = samples
        samples = []
        return out
    }

    /// Stops and discards.
    public func cancel() {
        _ = stop()
    }

    // MARK: - Engine

    private func buildAndStartEngine() throws {
        tearDownEngine()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }

        let converter = AudioConverter()
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let mono = try? converter.resampleBuffer(buffer) else { return }
            self.lock.lock()
            if self.isRecording { self.samples.append(contentsOf: mono) }
            self.lock.unlock()
        }
        engine.prepare()
        try engine.start()

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.logger.info("audio engine configuration changed; rebuilding")
            self.lock.lock(); let active = self.isRecording; self.lock.unlock()
            if active {
                do { try self.buildAndStartEngine() } catch { self.logger.error("audio engine rebuild failed: \(error)") }
            }
        }

        self.engine = engine
        self.converter = converter
    }

    private func tearDownEngine() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        engine = nil
        converter = nil
    }
}
