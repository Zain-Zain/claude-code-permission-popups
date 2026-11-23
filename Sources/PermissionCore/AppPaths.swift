import Foundation

public enum AppPaths {
    public static let bundleIdentifier = "local.permission-popups"

    /// `~/Library/Application Support/local.permission-popups`
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public static var socketPath: String {
        supportDirectory.appendingPathComponent("agent.sock").path
    }

    public static var historyURL: URL {
        supportDirectory.appendingPathComponent("history.jsonl")
    }

    /// Creates the support directory with mode 0700, or tightens an existing one to 0700.
    public static func ensureSupportDirectory() throws {
        try ensureDirectory(at: supportDirectory)
    }

    static func ensureDirectory(at url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
