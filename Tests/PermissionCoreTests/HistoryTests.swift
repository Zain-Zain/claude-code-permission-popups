import Foundation
import Testing
@testable import PermissionCore

@Suite struct HistoryTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.jsonl")
    }

    func entry(_ n: Int, outcome: HistoryEntry.Outcome = .allowed) -> HistoryEntry {
        HistoryEntry(id: UUID(), date: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)),
                     outcome: outcome, tool: "Bash", headline: "h\(n)", primary: "cmd \(n)",
                     cwd: "~/proj", sessionPrefix: "abcd1234")
    }

    @Test func appendAndLoadNewestFirst() throws {
        let store = HistoryStore(fileURL: tempURL())
        let a = entry(1), b = entry(2, outcome: .denied)
        try store.append(a)
        try store.append(b)
        #expect(store.load() == [b, a])
    }

    @Test func loadMissingFileIsEmpty() {
        #expect(HistoryStore(fileURL: tempURL()).load() == [])
    }

    @Test func datesAreISO8601() throws {
        let url = tempURL()
        try HistoryStore(fileURL: url).append(entry(0))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("2023-11-14T22:13:20Z"))
    }

    @Test func fileModeIs0600() throws {
        let url = tempURL()
        try HistoryStore(fileURL: url).append(entry(1))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func looseExistingFileIsTightenedOnAppend() throws {
        let url = tempURL()
        let store = HistoryStore(fileURL: url)
        try store.append(entry(1))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try store.append(entry(2))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func trimKeepsLimit() throws {
        let url = tempURL()
        let store = HistoryStore(fileURL: url)
        for i in 0..<1005 { try store.append(entry(i)) }
        try store.trim()
        let loaded = store.load()
        #expect(loaded.count == 1000)
        #expect(loaded.first?.headline == "h1004")
        #expect(loaded.last?.headline == "h5")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func loadSkipsCorruptLine() throws {
        let url = tempURL()
        let store = HistoryStore(fileURL: url)
        try store.append(entry(1))
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("{not json\n\n".utf8))
        try h.close()
        try store.append(entry(2))
        #expect(store.load().map(\.headline) == ["h2", "h1"])
    }

    @Test func clearEmpties() throws {
        let store = HistoryStore(fileURL: tempURL())
        try store.append(entry(1))
        try store.clear()
        #expect(store.load() == [])
        try store.append(entry(2))
        #expect(store.load().count == 1)
    }

    @Test func clearOnMissingFileDoesNotThrow() throws {
        try HistoryStore(fileURL: tempURL()).clear()
    }

    @Test func entryFromPending() throws {
        let data = Data(#"{"hook_event_name":"PermissionRequest","session_id":"0123456789abcdef","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/x/proj"}"#.utf8)
        let p = PendingRequest(request: try PermissionRequest(json: data), homeDirectory: "/x")
        let e = HistoryEntry(pending: p, outcome: .alwaysAllowed)
        #expect(e.sessionPrefix == "01234567")
        #expect(e.tool == "Bash")
        #expect(e.headline == p.summary.headline)
        #expect(e.primary == "ls")
        #expect(e.cwd == "~/proj")
        #expect(e.outcome == .alwaysAllowed)
    }
}
