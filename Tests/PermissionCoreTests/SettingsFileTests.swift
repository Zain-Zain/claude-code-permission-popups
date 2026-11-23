import Foundation
import Testing
@testable import PermissionCore

@Suite(.serialized)
struct SettingsFileTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    private func backups(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".bak-") }.sorted()
    }

    private func put(_ text: String, at url: URL, mode: Int) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    @Test func symlinkTargetUpdatedLinkKept() throws {
        let dir = try tempDir()
        let real = dir.appendingPathComponent("real.json")
        let link = dir.appendingPathComponent("settings.json")
        try put("old", at: real, mode: 0o600)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try SettingsFile(url: link).update { _ in Data("new".utf8) }

        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(try String(contentsOf: real) == "new")
        #expect(try mode(real) == 0o600)
        #expect(try backups(in: dir).count == 1)
        #expect(try backups(in: dir).allSatisfy { $0.hasPrefix("real.json.bak-") })
    }

    @Test func backupNeverOverwrites() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("settings.json")
        try put("v0", at: file, mode: 0o600)
        let sf = SettingsFile(url: file)
        try sf.update { _ in Data("v1".utf8) }
        try sf.update { _ in Data("v2".utf8) }
        try sf.update { _ in Data("v3".utf8) }
        let names = try backups(in: dir)
        #expect(names.count == 3)
        let contents = try names.map { try String(contentsOf: dir.appendingPathComponent($0)) }
        #expect(Set(contents) == ["v0", "v1", "v2"])
    }

    @Test func newFileIs0600() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent(".claude/settings.json")
        try SettingsFile(url: file).update { _ in Data("x".utf8) }
        #expect(try mode(file) == 0o600)
        #expect(try mode(file.deletingLastPathComponent()) == 0o700)
        #expect(try backups(in: file.deletingLastPathComponent()).isEmpty)
    }

    @Test func preservesExistingMode0640() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("settings.json")
        try put("a", at: file, mode: 0o640)
        try SettingsFile(url: file).update { _ in Data("b".utf8) }
        #expect(try mode(file) == 0o640)
        #expect(try mode(dir.appendingPathComponent(try backups(in: dir)[0])) == 0o640)
    }

    @Test func throwWritesNothing() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("settings.json")
        try put("{ // c", at: file, mode: 0o600)
        let before = try Data(contentsOf: file)
        #expect(throws: HookSettingsError.invalidJSON) {
            try SettingsFile(url: file).update { try HookSettings.install(into: $0, helperPath: "/x/permission-hook") }
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(try backups(in: dir).isEmpty)
    }

    @Test func concurrentChangeIsRecomputed() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("settings.json")
        try put("one", at: file, mode: 0o600)
        var computed: [String?] = []
        try SettingsFile(url: file).update(confirm: {
            try? "two".write(to: file, atomically: true, encoding: .utf8)  // edited while the alert is open
            return true
        }, compute: { data in
            let s = data.flatMap { String(data: $0, encoding: .utf8) }
            computed.append(s)
            return Data(((s ?? "") + "+mine").utf8)
        })
        #expect(computed == ["one", "two"])
        #expect(try String(contentsOf: file) == "two+mine")
    }

    @Test func recomputeThatThrowsWritesNothing() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("settings.json")
        try put("{}", at: file, mode: 0o600)
        #expect(throws: HookSettingsError.invalidJSON) {
            try SettingsFile(url: file).update(confirm: {
                try? "{ // c".write(to: file, atomically: true, encoding: .utf8)
                return true
            }, compute: { try HookSettings.install(into: $0, helperPath: "/x/permission-hook") })
        }
        #expect(try String(contentsOf: file) == "{ // c")
        #expect(try backups(in: dir).isEmpty)
    }

    @Test func unreadableFileIsError() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("settings.json")
        try put("secret", at: file, mode: 0o000)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        var called = false
        #expect(throws: (any Error).self) {
            try SettingsFile(url: file).update { _ in called = true; return Data("x".utf8) }
        }
        #expect(!called)
        #expect(try backups(in: dir).isEmpty)
    }

    @Test func danglingSymlinkIsError() throws {
        let dir = try tempDir()
        let link = dir.appendingPathComponent("settings.json")
        let missing = dir.appendingPathComponent("nowhere.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
        #expect(throws: SettingsFileError.danglingSymlink(link.path)) {
            try SettingsFile(url: link).update { _ in Data("x".utf8) }
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    @Test func homeOverrideUsed() {
        let old = getenv("HOME").map { String(cString: $0) }
        defer { if let old { setenv("HOME", old, 1) } else { unsetenv("HOME") } }
        setenv("HOME", "/tmp/pp-home-test", 1)
        #expect(AppPaths.homeDirectory.path == "/tmp/pp-home-test")
        #expect(AppPaths.supportDirectory.path.hasPrefix("/tmp/pp-home-test/Library/"))
        setenv("HOME", "relative", 1)
        #expect(AppPaths.homeDirectory == FileManager.default.homeDirectoryForCurrentUser)
    }
}
