import Foundation
import AVFoundation
import FluidAudio

/// Speech-to-text via FluidAudio's Parakeet TDT (Core ML, Apple Neural Engine).
/// Loads strictly from a local directory; downloading is a separate explicit step (`ModelManager`).
public actor Transcriber {
    public struct Result: Sendable {
        public var text: String
        public var audioSeconds: Double
        public var processingMs: Double
        public var confidence: Float
    }

    public enum TranscriberError: Error, LocalizedError {
        case notLoaded
        case modelsMissing(URL)
        public var errorDescription: String? {
            switch self {
            case .notLoaded: return "STT models are not loaded"
            case .modelsMissing(let u): return "STT models missing at \(u.path)"
            }
        }
    }

    public static let sampleRate = 16_000
    /// FluidAudio rejects audio shorter than 0.3 s; we zero-pad up to this.
    public static let minimumSamples = 4_800

    private var manager: AsrManager?
    private var decoderLayers = 2
    public private(set) var loadedFrom: URL?

    public init() {}

    public var isLoaded: Bool { manager != nil }

    /// Model version for a configured repo id ("…/parakeet-tdt-0.6b-v3-coreml" → .v3).
    nonisolated public static func version(for sttModel: String) -> AsrModelVersion {
        if sttModel.lowercased().contains("v2") { return .v2 }
        return .v3
    }

    /// Where the STT models live: `<modelsDir>/<FluidAudio folder name>`. FluidAudio names the
    /// folder after the model, not the HF repo (`parakeet-tdt-0.6b-v3`, see FluidAudio `Repo.folderName`),
    /// and `AsrModels.download(to:)` always writes to `<parent>/<folderName>`.
    nonisolated public static func modelDirectory(for sttModel: String, modelsDir: URL = LocalFlowPaths.modelsDir) -> URL {
        let folder: String
        switch version(for: sttModel) {
        case .v2: folder = "parakeet-tdt-0.6b-v2"
        default: folder = "parakeet-tdt-0.6b-v3"
        }
        return modelsDir.appendingPathComponent(folder, isDirectory: true)
    }

    nonisolated public static func modelsArePresent(for sttModel: String, modelsDir: URL = LocalFlowPaths.modelsDir) -> Bool {
        let dir = modelDirectory(for: sttModel, modelsDir: modelsDir)
        return AsrModels.modelsExist(at: dir, version: version(for: sttModel))
    }

    /// Load from disk only. Never touches the network.
    public func load(sttModel: String, modelsDir: URL = LocalFlowPaths.modelsDir) async throws {
        let dir = Self.modelDirectory(for: sttModel, modelsDir: modelsDir)
        let v = Self.version(for: sttModel)
        guard AsrModels.modelsExist(at: dir, version: v) else { throw TranscriberError.modelsMissing(dir) }
        let models = try AsrModels.loadLocal(from: dir, version: v)
        let m = AsrManager(config: .default, models: models)
        decoderLayers = await m.decoderLayerCount
        manager = m
        loadedFrom = dir
    }

    /// One dummy pass so the first real utterance does not pay the ANE specialization cost.
    public func warmUp() async throws {
        _ = try await transcribe(samples: [Float](repeating: 0, count: Self.minimumSamples * 2))
    }

    /// Transcribe 16 kHz mono Float32 samples. Short audio is zero-padded to the 0.3 s minimum.
    public func transcribe(samples: [Float]) async throws -> Result {
        guard let manager else { throw TranscriberError.notLoaded }
        var audio = samples
        if audio.count < Self.minimumSamples {
            audio.append(contentsOf: [Float](repeating: 0, count: Self.minimumSamples - audio.count))
        }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let t0 = DispatchTime.now()
        let r = try await manager.transcribe(audio, decoderState: &state)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        return Result(text: r.text.trimmingCharacters(in: .whitespacesAndNewlines),
                      audioSeconds: Double(samples.count) / Double(Self.sampleRate),
                      processingMs: ms,
                      confidence: r.confidence)
    }

    public func unload() async {
        await manager?.cleanup()
        manager = nil
        loadedFrom = nil
    }
}
