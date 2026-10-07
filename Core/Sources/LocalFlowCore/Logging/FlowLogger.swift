import Foundation

/// Append-only file logger. Policy: timings and errors only — never transcript text
/// (callers enforce this; `DictationHistory` is the only place text is persisted, and only when enabled).
public final class FlowLogger: @unchecked Sendable {
    public enum Level: String { case info = "INFO", warn = "WARN", error = "ERROR", timing = "TIMING" }

    public static let shared = FlowLogger(url: LocalFlowPaths.logFile)

    private let url: URL
    private let lock = NSLock()
    private let mirrorToStderr: Bool
    private let maxBytes: UInt64
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(url: URL, mirrorToStderr: Bool = false, maxBytes: UInt64 = 5 * 1024 * 1024) {
        self.url = url
        self.mirrorToStderr = mirrorToStderr
        self.maxBytes = maxBytes
    }

    public func info(_ message: String) { log(.info, message) }
    public func warn(_ message: String) { log(.warn, message) }
    public func error(_ message: String) { log(.error, message) }

    /// Per-stage timing line, e.g. `TIMING record=10234ms stt=412ms llm=531ms paste=18ms total=961ms`
    public func timing(_ fields: [(String, Double)]) {
        let body = fields.map { String(format: "%@=%.0fms", $0.0, $0.1) }.joined(separator: " ")
        log(.timing, body)
    }

    public func log(_ level: Level, _ message: String) {
        let line = "\(Self.formatter.string(from: Date())) [\(level.rawValue)] \(message)\n"
        lock.lock(); defer { lock.unlock() }
        if mirrorToStderr { FileHandle.standardError.write(Data(line.utf8)) }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64, size > maxBytes {
                let rotated = url.deletingPathExtension().appendingPathExtension("1.log")
                try? fm.removeItem(at: rotated)
                try? fm.moveItem(at: url, to: rotated)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // Logging must never crash the app; drop the line.
        }
    }
}
