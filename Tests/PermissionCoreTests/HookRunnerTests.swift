import Foundation
import Testing
@testable import PermissionCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var seen: [JSONValue] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    var requests: [JSONValue] { lock.lock(); defer { lock.unlock() }; return seen }
    func hit(_ r: JSONValue) { lock.lock(); n += 1; seen.append(r); lock.unlock() }
}

/// Key order in encoded JSON is not stable, so compare parsed values.
private func parsed(_ d: Data?) -> JSONValue? {
    d.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
}

private func socketPath() -> String { "/tmp/pp-\(UUID().uuidString.prefix(8).lowercased()).sock" }

private func runInBackground(_ input: Data, _ path: String) async -> Data? {
    await withCheckedContinuation { c in
        DispatchQueue.global().async { c.resume(returning: HookRunner.run(stdin: input, socketPath: path)) }
    }
}

/// Starts a server that answers every request with `reply`.
private func serve(_ path: String, reply: WireReply, counter: Counter = Counter()) throws -> SocketServer {
    let server = SocketServer(path: path) { req, responder in
        counter.hit(req.request)
        responder.reply(reply)
    }
    try server.start()
    return server
}

@Suite(.serialized) struct HookRunnerTests {
    @Test func allowFlowsThrough() async throws {
        let path = socketPath()
        let counter = Counter()
        let server = try serve(path, reply: WireReply(.allow), counter: counter)
        defer { server.stop() }
        let input = try fixture("bash")
        let out = await runInBackground(input, path)
        #expect(parsed(out) != nil)
        #expect(parsed(out) == parsed(ClaudeHookOutput.encode(.allow)))
        // The app receives exactly what Claude Code sent.
        #expect(counter.requests.first == (try JSONDecoder().decode(JSONValue.self, from: input)))
    }

    @Test func denyFlowsThrough() async throws {
        let path = socketPath()
        let server = try serve(path, reply: WireReply(.deny(message: denyMessage)))
        defer { server.stop() }
        let out = await runInBackground(try fixture("bash"), path)
        #expect(parsed(out) != nil)
        #expect(parsed(out) == parsed(ClaudeHookOutput.encode(.deny(message: denyMessage))))
    }

    @Test func allowAlwaysFlowsThrough() async throws {
        let path = socketPath()
        let updates = [try PermissionRequest(json: fixture("bash")).permissionSuggestions[0]]
        let server = try serve(path, reply: WireReply(.allowAlways(updatedPermissions: updates)))
        defer { server.stop() }
        let out = await runInBackground(try fixture("bash"), path)
        #expect(parsed(out) != nil)
        #expect(parsed(out) == parsed(ClaudeHookOutput.encode(.allowAlways(updatedPermissions: updates))))
    }

    /// The helper enforces the Always Allow filter itself, whatever the app sends.
    @Test func helperRejectsSetModeFromApp() async throws {
        let path = socketPath()
        let setMode = JSONValue.object([
            "type": .string("setMode"), "mode": .string("bypassPermissions"), "destination": .string("userSettings"),
        ])
        let server = try serve(path, reply: WireReply(.allowAlways(updatedPermissions: [setMode])))
        defer { server.stop() }
        #expect(await runInBackground(try fixture("bash"), path) == nil)
    }

    /// Even an addRules/allow entry is refused unless Claude Code offered exactly that entry.
    @Test func helperRejectsUnsuggestedRule() async throws {
        let path = socketPath()
        let unsuggested = JSONValue.object([
            "type": .string("addRules"), "behavior": .string("allow"), "destination": .string("userSettings"),
            "rules": .array([.object(["toolName": .string("Bash")])]),
        ])
        let server = try serve(path, reply: WireReply(.allowAlways(updatedPermissions: [unsuggested])))
        defer { server.stop() }
        #expect(await runInBackground(try fixture("bash"), path) == nil)
    }

    /// A mix of offered and other entries forwards only the offered addRules/allow ones.
    @Test func helperForwardsOnlyOfferedRules() async throws {
        let path = socketPath()
        let suggestions = try PermissionRequest(json: fixture("bash")).permissionSuggestions
        let extra = JSONValue.object(["type": .string("addRules"), "behavior": .string("allow")])
        let server = try serve(path, reply: WireReply(.allowAlways(updatedPermissions: [extra] + suggestions)))
        defer { server.stop() }
        let out = await runInBackground(try fixture("bash"), path)
        #expect(parsed(out) != nil)
        #expect(parsed(out) == parsed(ClaudeHookOutput.encode(.allowAlways(updatedPermissions: [suggestions[0]]))))
    }

    @Test func helperIgnoresOtherWireVersion() async throws {
        let path = socketPath()
        let server = try serve(path, reply: WireReply(v: 2, decision: "allow", updatedPermissions: nil, message: nil))
        defer { server.stop() }
        #expect(await runInBackground(try fixture("bash"), path) == nil)
    }

    @Test func passPrintsNothing() async throws {
        let path = socketPath()
        let server = try serve(path, reply: WireReply(.pass))
        defer { server.stop() }
        #expect(await runInBackground(try fixture("bash"), path) == nil)
    }

    @Test func askUserQuestionSkipsSocket() async throws {
        let path = socketPath()
        let counter = Counter()
        let server = try serve(path, reply: WireReply(.allow), counter: counter)
        defer { server.stop() }
        #expect(await runInBackground(try fixture("ask_user_question"), path) == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.count == 0)
    }

    /// Plan approvals need `updatedInput`, which the popup cannot supply: Claude's own dialog answers them.
    @Test func exitPlanModeSkipsSocket() async throws {
        let path = socketPath()
        let counter = Counter()
        let server = try serve(path, reply: WireReply(.allow), counter: counter)
        defer { server.stop() }
        let input = Data(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{"plan":"1. Do it"}}"#.utf8)
        #expect(await runInBackground(input, path) == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.count == 0)
    }

    @Test func noServerPrintsNothing() throws {
        #expect(HookRunner.run(stdin: try fixture("bash"), socketPath: socketPath()) == nil)
    }

    @Test func garbageInputPrintsNothing() async throws {
        let path = socketPath()
        let counter = Counter()
        let server = try serve(path, reply: WireReply(.allow), counter: counter)
        defer { server.stop() }
        let inputs: [Data] = [
            Data(),
            Data("{".utf8),
            Data("[]".utf8),
            Data(#"{"hook_event_name":"PermissionRequest"}"#.utf8),
            Data(repeating: UInt8(ascii: "a"), count: 5 * 1024 * 1024),
        ]
        for input in inputs {
            #expect(await runInBackground(input, path) == nil)
        }
        #expect(counter.count == 0)
    }

    @Test func garbageReplyPrintsNothing() async throws {
        let path = socketPath()
        let server = try serve(path, reply: WireReply(v: 1, decision: "bogus", updatedPermissions: nil, message: nil))
        defer { server.stop() }
        #expect(await runInBackground(try fixture("bash"), path) == nil)
    }

    /// A raw server that writes "nope\n" instead of JSON.
    @Test func nonJSONReplyPrintsNothing() async throws {
        let path = socketPath()
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { close(listener); unlink(path) }
        let bound = try UnixSocket.withAddress(path) { bind(listener, $0, $1) }
        try #require(bound == 0)
        try #require(listen(listener, 1) == 0)
        DispatchQueue.global().async {
            let conn = accept(listener, nil, nil)
            guard conn >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            while true { // consume the request line
                let n = read(conn, &buf, buf.count)
                if n <= 0 || buf[0..<n].contains(0x0A) { break }
            }
            _ = UnixSocket.writeAll(conn, Data("nope\n".utf8))
            close(conn)
        }
        #expect(await runInBackground(try fixture("bash"), path) == nil)
    }
}
