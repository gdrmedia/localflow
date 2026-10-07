import Foundation

/// Every path LocalFlow touches on disk. Nothing outside these folders is written.
public enum LocalFlowPaths {
    public static let appName = "LocalFlow"

    /// Override root for tests (`LOCALFLOW_HOME`), otherwise the real home directory.
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["LOCALFLOW_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/Library/Application Support/LocalFlow
    public static var appSupport: URL {
        home.appendingPathComponent("Library/Application Support/LocalFlow", isDirectory: true)
    }
    /// ~/Library/Application Support/LocalFlow/config.json
    public static var configFile: URL { appSupport.appendingPathComponent("config.json") }
    /// ~/Library/Application Support/LocalFlow/history.jsonl (only written when historyEnabled)
    public static var historyFile: URL { appSupport.appendingPathComponent("history.jsonl") }
    /// ~/Library/Application Support/LocalFlow/models — both the Core ML STT models and the MLX LLM live here.
    public static var modelsDir: URL { appSupport.appendingPathComponent("models", isDirectory: true) }
    /// ~/Library/Logs/LocalFlow
    public static var logsDir: URL { home.appendingPathComponent("Library/Logs/LocalFlow", isDirectory: true) }
    /// ~/Library/Logs/LocalFlow/localflow.log
    public static var logFile: URL { logsDir.appendingPathComponent("localflow.log") }

    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [appSupport, modelsDir, logsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
