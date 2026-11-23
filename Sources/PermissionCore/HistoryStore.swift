import Foundation

public struct HistoryEntry: Codable, Equatable, Identifiable {
    public enum Outcome: String, Codable {
        case allowed, alwaysAllowed, denied, answeredElsewhere
    }

    public var id: UUID
    public var date: Date
    public var outcome: Outcome
    public var tool: String
    public var headline: String
    public var primary: String?
    public var cwd: String?
    public var sessionPrefix: String

    public init(id: UUID, date: Date, outcome: Outcome, tool: String, headline: String,
                primary: String?, cwd: String?, sessionPrefix: String) {
        self.id = id
        self.date = date
        self.outcome = outcome
        self.tool = tool
        self.headline = headline
        self.primary = primary
        self.cwd = cwd
        self.sessionPrefix = sessionPrefix
    }

    public init(pending: PendingRequest, outcome: Outcome, date: Date = Date()) {
        self.init(id: pending.id, date: date, outcome: outcome,
                  tool: pending.request.toolName,
                  headline: pending.summary.headline,
                  primary: pending.summary.primary,
                  cwd: pending.summary.cwd,
                  sessionPrefix: String(pending.request.sessionId.prefix(8)))
    }
}

/// Append-only JSON Lines history, one entry per line, file mode 0600.
///
/// Not thread-safe by design: use from the main thread only.
public final class HistoryStore {
    public let fileURL: URL
    public let limit: Int

    public init(fileURL: URL, limit: Int = 1000) {
        self.fileURL = fileURL
        self.limit = limit
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// O(1): opens the file, seeks to the end, writes one line. Creates the parent directory
    /// and the file (0600) if missing, and tightens a looser existing file to 0600.
    public func append(_ e: HistoryEntry) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var line = try Self.makeEncoder().encode(e)
        line.append(0x0A)
        if !fm.fileExists(atPath: fileURL.path) {
            guard fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try Self.ensureMode0600(fileURL)
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size > 0 {
            // A crash mid-append can leave a partial last line; start on a fresh line.
            try handle.seek(toOffset: size - 1)
            if try handle.read(upToCount: 1)?.first != 0x0A { line.insert(0x0A, at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
    }

    /// Newest first. A missing file yields `[]`; undecodable lines are skipped.
    public func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = Self.makeDecoder()
        var out: [HistoryEntry] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let e = try? decoder.decode(HistoryEntry.self, from: Data(line)) { out.append(e) }
        }
        return out.reversed()
    }

    /// Keeps the newest `limit` entries (and drops undecodable lines).
    public func trim() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let kept = Array(load().prefix(limit).reversed())
        let encoder = Self.makeEncoder()
        var data = Data()
        for e in kept {
            data.append(try encoder.encode(e))
            data.append(0x0A)
        }
        try data.write(to: fileURL, options: .atomic)
        try Self.ensureMode0600(fileURL)
    }

    public func clear() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        try Data().write(to: fileURL)
        try Self.ensureMode0600(fileURL)
    }

    private static func ensureMode0600(_ url: URL) throws {
        let fm = FileManager.default
        let mode = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        if mode != 0o600 {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
