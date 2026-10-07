import Foundation

/// One dictation, as shown in the History window.
public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var ts: Date
    public var raw: String
    public var cleaned: String
    /// Recording length in seconds.
    public var seconds: Double?
    /// Frontmost app at paste time.
    public var app: String?
    public var pasted: Bool?
    public var usedLLM: Bool?

    public init(id: UUID = UUID(), ts: Date = Date(), raw: String, cleaned: String, seconds: Double? = nil,
                app: String? = nil, pasted: Bool? = nil, usedLLM: Bool? = nil) {
        self.id = id; self.ts = ts; self.raw = raw; self.cleaned = cleaned
        self.seconds = seconds; self.app = app; self.pasted = pasted; self.usedLLM = usedLLM
    }

    enum CodingKeys: String, CodingKey { case id, ts, raw, cleaned, seconds, app, pasted, usedLLM }

    /// Tolerant: lines written by older builds have only ts/raw/cleaned.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        raw = (try? c.decodeIfPresent(String.self, forKey: .raw)) ?? ""
        cleaned = (try? c.decodeIfPresent(String.self, forKey: .cleaned)) ?? ""
        if let s = try? c.decodeIfPresent(String.self, forKey: .ts), let d = DictationHistory.parseDate(s) { ts = d } else { ts = Date() }
        seconds = try? c.decodeIfPresent(Double.self, forKey: .seconds)
        app = try? c.decodeIfPresent(String.self, forKey: .app)
        pasted = try? c.decodeIfPresent(Bool.self, forKey: .pasted)
        usedLLM = try? c.decodeIfPresent(Bool.self, forKey: .usedLLM)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(DictationHistory.formatDate(ts), forKey: .ts)
        try c.encode(raw, forKey: .raw)
        try c.encode(cleaned, forKey: .cleaned)
        try c.encodeIfPresent(seconds, forKey: .seconds)
        try c.encodeIfPresent(app, forKey: .app)
        try c.encodeIfPresent(pasted, forKey: .pasted)
        try c.encodeIfPresent(usedLLM, forKey: .usedLLM)
    }
}

/// JSON-lines store for dictation history (`history.jsonl`). Append-only on the hot path;
/// delete/clear rewrite the file. Safe to call from any thread.
public final class DictationHistory: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static func parseDate(_ s: String) -> Date? { iso.date(from: s) ?? isoPlain.date(from: s) }
    static func formatDate(_ d: Date) -> String { iso.string(from: d) }

    /// Back-compat convenience.
    public func append(raw: String, cleaned: String) {
        append(HistoryEntry(raw: raw, cleaned: cleaned))
    }

    public func append(_ entry: HistoryEntry) {
        guard var data = try? JSONEncoder().encode(entry) else { return }
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: url) {
            try? h.seekToEnd()
            try? h.write(contentsOf: data)
            try? h.close()
        }
    }

    /// Newest first. Malformed lines are skipped.
    public func load() -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return readAll().reversed()
    }

    public var count: Int { load().count }

    public func delete(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        let kept = readAll().filter { $0.id != id }
        writeAll(kept)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        writeAll([])
    }

    // MARK: - private (caller holds the lock)

    private func readAll() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let dec = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { line in
            guard !line.isEmpty else { return nil }
            return try? dec.decode(HistoryEntry.self, from: Data(line))
        }
    }

    private func writeAll(_ entries: [HistoryEntry]) {
        let enc = JSONEncoder()
        var out = Data()
        for e in entries {
            if let d = try? enc.encode(e) { out.append(d); out.append(0x0A) }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? out.write(to: url, options: .atomic)
    }
}
