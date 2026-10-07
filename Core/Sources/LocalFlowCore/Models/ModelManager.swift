import Foundation
import FluidAudio
import HuggingFace

/// Model presence checks and the one explicit download step. Everything else in the app
/// loads from `LocalFlowPaths.modelsDir` with the network disabled.
public enum ModelManager {
    public enum ModelError: Error, LocalizedError {
        case badRepoID(String)
        public var errorDescription: String? {
            if case .badRepoID(let s) = self { return "not an org/name Hugging Face repo id: \(s)" }
            return nil
        }
    }

    public static let llmFilePatterns = ["*.safetensors", "*.json", "*.jinja", "*.txt", "*.model", "*.tiktoken"]

    public struct Status: Sendable {
        public var sttPresent: Bool
        public var llmPresent: Bool
        public var sttDirectory: URL
        public var llmDirectory: URL
        public var sttBytes: Int64
        public var llmBytes: Int64
        public var allPresent: Bool { sttPresent && llmPresent }
    }

    /// `<modelsDir>/<org>/<name>/` holding config.json, *.safetensors, tokenizer files.
    public static func llmDirectory(for id: String, modelsDir: URL = LocalFlowPaths.modelsDir) -> URL {
        modelsDir.appendingPathComponent(id, isDirectory: true)
    }

    public static func llmPresent(at dir: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { return false }
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        let hasWeights = items.contains { $0.hasSuffix(".safetensors") }
        let hasTokenizer = items.contains("tokenizer.json") || items.contains("tokenizer.model") || items.contains("tokenizer_config.json")
        return hasWeights && hasTokenizer
    }

    public static func status(config: AppConfig, modelsDir: URL = LocalFlowPaths.modelsDir) -> Status {
        let sttDir = Transcriber.modelDirectory(for: config.sttModel, modelsDir: modelsDir)
        let llmDir = llmDirectory(for: config.llmModel, modelsDir: modelsDir)
        return Status(sttPresent: Transcriber.modelsArePresent(for: config.sttModel, modelsDir: modelsDir),
                      llmPresent: llmPresent(at: llmDir),
                      sttDirectory: sttDir, llmDirectory: llmDir,
                      sttBytes: directorySize(sttDir), llmBytes: directorySize(llmDir))
    }

    /// Hard guard: FluidAudio must never download on its own after setup.
    public static func enforceOffline() {
        ModelHub.offlineMode = true
        AppLogger.minimumLevel = .warning   // debug lines can echo transcript text
    }

    /// Download the Parakeet Core ML bundles into `<modelsDir>/<repo folder>/`.
    @discardableResult
    public static func downloadSTT(sttModel: String, modelsDir: URL = LocalFlowPaths.modelsDir,
                                   progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let dir = Transcriber.modelDirectory(for: sttModel, modelsDir: modelsDir)
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        ModelHub.offlineMode = false
        defer { ModelHub.offlineMode = true }
        return try await AsrModels.download(to: dir, version: Transcriber.version(for: sttModel),
                                            progressHandler: { p in progress(p.fractionCompleted) })
    }

    /// Download an MLX model snapshot (weights + tokenizer) straight into `<modelsDir>/<org>/<name>/`.
    @discardableResult
    public static func downloadLLM(id: String, modelsDir: URL = LocalFlowPaths.modelsDir,
                                   progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else { throw ModelError.badRepoID(id) }
        let dir = llmDirectory(for: id, modelsDir: modelsDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let client = HubClient(cache: nil)
        do {
            return try await client.downloadSnapshot(of: repo, to: dir, revision: "main", matching: llmFilePatterns,
                                                     progressHandler: { @MainActor p in progress(p.fractionCompleted) })
        } catch HubCacheError.snapshotRequiresCacheOrDestination {
            // swift-huggingface 0.9.0 writes every file straight into `dir` when there is no cache, then throws
            // this from its final "copy snapshot" step. The download itself is complete; verify and carry on.
            guard llmPresent(at: dir) else { throw HubCacheError.snapshotRequiresCacheOrDestination(id) }
            return dir
        }
    }

    public static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }

    public static func humanBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
