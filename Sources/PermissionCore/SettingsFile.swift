import Foundation

public enum SettingsFileError: Error, Equatable, LocalizedError {
    case danglingSymlink(String)

    public var errorDescription: String? {
        switch self {
        case .danglingSymlink(let path): return "\(path) is a symbolic link to a file that does not exist."
        }
    }
}

/// Safe read-modify-write of a user-owned config file (Claude Code's settings.json).
/// - Symlinks are resolved first; every step works on the real target and the link stays.
/// - The new contents are computed before anything is touched; a throw writes nothing.
/// - The file is re-read after confirmation and recomputed if it changed meanwhile.
/// - An existing file is backed up (never overwriting a backup) before it is replaced.
/// - The replacement is created at its final mode and renamed into place.
public struct SettingsFile {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// The file's contents, or nil if it does not exist. Any other failure throws.
    public func read() throws -> Data? {
        try Self.readResolved(try resolved())
    }

    /// Computes the new contents with `compute` (nil means "nothing to do"), asks `confirm`
    /// (if given), re-reads, recomputes if the file changed, then writes.
    /// Returns true if the file was written.
    @discardableResult
    public func update(confirm: (() -> Bool)? = nil,
                       compute: (Data?) throws -> Data?) throws -> Bool {
        let target = try resolved()
        let before = try Self.readResolved(target)
        guard var updated = try compute(before) else { return false }
        if updated == before { return false }

        if let confirm, !confirm() { return false }

        let fresh = try Self.readResolved(target)
        if fresh != before {
            guard let recomputed = try compute(fresh) else { return false }
            if recomputed == fresh { return false }
            updated = recomputed
        }
        try write(updated, to: target, existed: fresh != nil)
        return true
    }

    // MARK: - Internals

    private func resolved() throws -> URL {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
            let target = url.resolvingSymlinksInPath()
            guard fm.fileExists(atPath: target.path) else {
                throw SettingsFileError.danglingSymlink(url.path)
            }
            return target
        }
        return url
    }

    private static func readResolved(_ target: URL) throws -> Data? {
        do {
            return try Data(contentsOf: target)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func write(_ data: Data, to target: URL, existed: Bool) throws {
        let fm = FileManager.default
        let directory = target.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }

        var mode = 0o600
        if existed {
            mode = (try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) ?? 0o600
            try backUp(target, mode: mode)
        }

        let temp = directory.appendingPathComponent(".\(target.lastPathComponent).tmp-\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)  // beats the umask
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard rename(temp.path, target.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// `<name>.bak-<yyyyMMdd-HHmmss>`, with `-2`, `-3`… added if that name is taken.
    private func backUp(_ target: URL, mode: Int) throws {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = target.path + ".bak-" + formatter.string(from: Date())
        var destination = base
        var n = 2
        while fm.fileExists(atPath: destination) {
            destination = "\(base)-\(n)"
            n += 1
        }
        try fm.copyItem(atPath: target.path, toPath: destination)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: destination)
    }
}
