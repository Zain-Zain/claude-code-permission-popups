import Foundation
import Testing
@testable import PermissionCore

/// Thread-safe mutable value shared between test code, the main queue and socket queues.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}

private struct WeakResponder { weak var object: SocketResponder?; init() {}; init(_ o: SocketResponder) { object = o } }

private func testSocketPath() -> String {
    "/tmp/pp-\(UUID().uuidString.prefix(8).lowercased()).sock"
}

private func requestLine() throws -> Data {
    try JSONEncoder().encode(WireRequest(request: .object(["tool_name": .string("Bash")])))
}

/// Polls `condition` until it holds or `timeout` passes.
private func eventually(within timeout: Duration = .seconds(1), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Runs the blocking `SocketClient.exchange` off the cooperative pool.
private func exchangeInBackground(path: String, line: Data) async -> Result<Data, Error> {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: Result { try SocketClient.exchange(path: path, line: line) })
        }
    }
}

private func socketError(_ result: Result<Data, Error>) -> SocketError? {
    if case .failure(let e) = result { return e as? SocketError }
    return nil
}

/// Raw client fd with a receive timeout so a broken server fails the test instead of hanging it.
private func rawClient(_ path: String) throws -> Int32 {
    let fd = try UnixSocket.connect(path: path)
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

/// Blocking read until EOF (or receive timeout). Returns the bytes read and whether EOF was seen.
private func readToEOF(_ fd: Int32) async -> (Data, Bool) {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n > 0 { data.append(contentsOf: chunk[0..<n]); continue }
                if n < 0 && errno == EINTR { continue }
                continuation.resume(returning: (data, n == 0))
                return
            }
        }
    }
}

private func sendLine(_ fd: Int32, _ line: Data) {
    var out = line
    out.append(0x0A)
    _ = UnixSocket.writeAll(fd, out)
}

@Suite(.serialized) struct SocketTests {
    @Test func roundTrip() async throws {
        let path = testSocketPath()
        let received = Box<JSONValue?>(nil)
        let onMain = Box(false)
        let server = SocketServer(path: path) { req, responder in
            received.value = req.request
            onMain.value = Thread.isMainThread
            responder.reply(WireReply(.allow))
        }
        try server.start()
        defer { server.stop(); unlink(path) }

        let result = await exchangeInBackground(path: path, line: try requestLine())
        let reply = try JSONDecoder().decode(WireReply.self, from: try result.get())
        #expect(reply.decision == "allow")
        #expect(received.value?["tool_name"] == .string("Bash"))
        #expect(onMain.value)
    }

    @Test func clientFailsFastWithoutServer() {
        let path = testSocketPath()
        let start = ContinuousClock.now
        #expect(throws: SocketError.connectFailed) {
            try SocketClient.exchange(path: path, line: Data("{}".utf8))
        }
        #expect(ContinuousClock.now - start < .milliseconds(100))
    }

    @Test func staleSocketIsReplaced() async throws {
        let path = testSocketPath()
        FileManager.default.createFile(atPath: path, contents: Data("junk".utf8))
        let server = SocketServer(path: path) { _, responder in responder.reply(WireReply(.allow)) }
        try server.start()
        defer { server.stop(); unlink(path) }

        let result = await exchangeInBackground(path: path, line: try requestLine())
        #expect(try JSONDecoder().decode(WireReply.self, from: try result.get()).decision == "allow")
    }

    /// Review Focus 2: a socket file left behind by a crashed app.
    @Test func staleSocketFromCrash() async throws {
        let path = testSocketPath()
        defer { unlink(path) }
        // Bind a socket and close it without unlinking, as a crashed process would.
        let dead = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(dead >= 0)
        let bound = try UnixSocket.withAddress(path) { bind(dead, $0, $1) }
        try #require(bound == 0)
        listen(dead, 1)
        close(dead)
        try #require(FileManager.default.fileExists(atPath: path))

        // The helper fails fast with connectFailed (ECONNREFUSED).
        let start = ContinuousClock.now
        #expect(throws: SocketError.connectFailed) {
            try SocketClient.exchange(path: path, line: try requestLine())
        }
        #expect(ContinuousClock.now - start < .milliseconds(100))

        // The app unlinks the stale file and rebinds.
        let server = SocketServer(path: path) { _, responder in responder.reply(WireReply(.allow)) }
        try server.start()
        defer { server.stop() }
        let result = await exchangeInBackground(path: path, line: try requestLine())
        #expect(try JSONDecoder().decode(WireReply.self, from: try result.get()).decision == "allow")
    }

    @Test func socketFileMode() throws {
        let path = testSocketPath()
        let server = SocketServer(path: path) { _, _ in }
        try server.start()
        defer { server.stop(); unlink(path) }

        var st = stat()
        try #require(lstat(path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(st.st_mode & S_IFMT == S_IFSOCK)
    }

    @Test func onCloseFiresWhenClientDisappears() async throws {
        let path = testSocketPath()
        let responder = Box<SocketResponder?>(nil)
        let closes = Box(0)
        let closeOnMain = Box(false)
        let server = SocketServer(path: path) { _, r in
            r.onClose = {
                closeOnMain.value = Thread.isMainThread
                closes.mutate { $0 += 1 }
            }
            responder.value = r
        }
        try server.start()
        defer { server.stop(); unlink(path) }

        let fd = try rawClient(path)
        sendLine(fd, try requestLine())
        #expect(await eventually { responder.value != nil })
        close(fd)

        #expect(await eventually { closes.value == 1 })
        #expect(closeOnMain.value)
        // A reply after the peer has gone does nothing and does not fire onClose again.
        responder.value?.reply(WireReply(.allow))
        try await Task.sleep(for: .milliseconds(100))
        #expect(closes.value == 1)
        #expect(responder.value?.outcome == .peerClosed)
    }

    @Test func onCloseIsReleasedAfterFiring() async throws {
        let path = testSocketPath()
        let weakRef = Box<WeakResponder>(WeakResponder())
        let fired = Box(false)
        let server = SocketServer(path: path) { _, r in
            // The closure captures the responder strongly, forming a cycle unless onClose is cleared.
            r.onClose = { fired.value = true; _ = r.id }
            weakRef.value = WeakResponder(r)
        }
        try server.start()
        defer { server.stop(); unlink(path) }

        let fd = try rawClient(path)
        sendLine(fd, try requestLine())
        #expect(await eventually { weakRef.value.object != nil })
        close(fd)
        #expect(await eventually { fired.value })
        #expect(await eventually { weakRef.value.object == nil })
    }

    @Test func rejectsOversizeLine() async throws {
        let path = testSocketPath()
        let calls = Box(0)
        let server = SocketServer(path: path) { _, _ in calls.mutate { $0 += 1 } }
        try server.start()
        defer { server.stop(); unlink(path) }

        let huge = Data(repeating: UInt8(ascii: "a"), count: 9 * 1024 * 1024)
        let result = await exchangeInBackground(path: path, line: huge)
        #expect(socketError(result) == .closed)
        #expect(calls.value == 0)
    }

    @Test func pathTooLong() {
        let path = "/tmp/" + String(repeating: "x", count: 115)
        #expect(path.utf8.count == 120)
        let server = SocketServer(path: path) { _, _ in }
        #expect(throws: SocketError.pathTooLong) { try server.start() }
        #expect(throws: SocketError.pathTooLong) { try SocketClient.exchange(path: path, line: Data()) }
    }

    @Test func supportPathsFitSocketLimit() {
        #expect(AppPaths.socketPath.utf8.count < 104)
        #expect(AppPaths.supportDirectory.path.hasSuffix("/Library/Application Support/local.permission-popups"))
        #expect(AppPaths.socketPath == AppPaths.supportDirectory.appendingPathComponent("agent.sock").path)
        #expect(AppPaths.historyURL == AppPaths.supportDirectory.appendingPathComponent("history.jsonl"))
        #expect(AppPaths.bundleIdentifier == "local.permission-popups")
    }

    @Test func ensureDirectoryCreatesAndTightensMode() throws {
        let base = URL(fileURLWithPath: "/tmp/pp-dir-\(UUID().uuidString.prefix(8).lowercased())")
        defer { try? FileManager.default.removeItem(at: base) }

        // New nested directory → 0700.
        let fresh = base.appendingPathComponent("a/b")
        try AppPaths.ensureDirectory(at: fresh)
        var st = stat()
        try #require(stat(fresh.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700)

        // Existing 0755 directory → chmodded to 0700.
        let existing = base.appendingPathComponent("loose")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try AppPaths.ensureDirectory(at: existing)
        try #require(stat(existing.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700)
    }

    @Test func malformedFirstLineClosesWithoutCallback() async throws {
        let path = testSocketPath()
        let calls = Box(0)
        let server = SocketServer(path: path) { _, _ in calls.mutate { $0 += 1 } }
        try server.start()
        defer { server.stop(); unlink(path) }

        for line in ["nope", "", "{\"v\":1}", "[]"] {
            let result = await exchangeInBackground(path: path, line: Data(line.utf8))
            #expect(socketError(result) == .closed, "line: \(line)")
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.value == 0)
    }

    @Test func silentClientIsDroppedAfterFirstLineTimeout() async throws {
        let path = testSocketPath()
        let calls = Box(0)
        let server = SocketServer(path: path) { _, _ in calls.mutate { $0 += 1 } }
        server.firstLineTimeout = 0.2
        try server.start()
        defer { server.stop(); unlink(path) }

        let fd = try rawClient(path)
        defer { close(fd) }
        let start = ContinuousClock.now
        let (data, sawEOF) = await readToEOF(fd)
        #expect(sawEOF)
        #expect(data.isEmpty)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(calls.value == 0)
    }

    @Test func defaultFirstLineTimeoutIsTenSeconds() {
        #expect(SocketServer(path: testSocketPath()) { _, _ in }.firstLineTimeout == 10)
    }

    @Test func foreignPeerIsRejected() async throws {
        let path = testSocketPath()
        let calls = Box(0)
        let server = SocketServer(path: path) { _, _ in calls.mutate { $0 += 1 } }
        server.allowedUID = getuid() &+ 1
        try server.start()
        defer { server.stop(); unlink(path) }

        let result = await exchangeInBackground(path: path, line: try requestLine())
        #expect(socketError(result) == .closed)
        #expect(calls.value == 0)
    }

    @Test func replyIsWrittenOnceThenClosed() async throws {
        let path = testSocketPath()
        let closes = Box(0)
        let server = SocketServer(path: path) { _, r in
            r.onClose = { closes.mutate { $0 += 1 } }
            r.reply(WireReply(.deny(message: denyMessage)))
            r.reply(WireReply(.allow))
        }
        try server.start()
        defer { server.stop(); unlink(path) }

        let fd = try rawClient(path)
        defer { close(fd) }
        sendLine(fd, try requestLine())
        let (data, sawEOF) = await readToEOF(fd)
        #expect(sawEOF)
        // Exactly one line, terminated by "\n", carrying the first reply.
        #expect(data.last == 0x0A)
        #expect(data.filter { $0 == 0x0A }.count == 1)
        #expect(try JSONDecoder().decode(WireReply.self, from: data.dropLast()) == WireReply(.deny(message: denyMessage)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(closes.value == 0)
    }

    /// A reply racing a peer close yields exactly one of: reply written, or onClose fired.
    @Test func replyRacingPeerCloseIsExactlyOnce() async throws {
        let path = testSocketPath()
        let responders = Box<[SocketResponder]>([])
        let closes = Box<[UUID: Int]>([:])
        let server = SocketServer(path: path) { _, r in
            r.onClose = { closes.mutate { $0[r.id, default: 0] += 1 } }
            responders.mutate { $0.append(r) }
            r.reply(WireReply(.allow))
        }
        try server.start()
        defer { server.stop(); unlink(path) }

        let rounds = 40
        let line = try requestLine()
        for i in 0..<rounds {
            let fd = try rawClient(path)
            sendLine(fd, line)
            if i % 2 == 1 { usleep(UInt32(i * 50)) }
            close(fd)
        }

        #expect(await eventually(within: .seconds(3)) {
            let rs = responders.value
            return rs.count == rounds && rs.allSatisfy { $0.outcome != .pending }
        })
        // Let any queued onClose callbacks drain.
        try await Task.sleep(for: .milliseconds(100))
        let counts = closes.value
        for r in responders.value {
            switch r.outcome {
            case .replied: #expect(counts[r.id] == nil)
            case .peerClosed: #expect(counts[r.id] == 1)
            default: Issue.record("unexpected outcome \(r.outcome)")
            }
        }
    }

    @Test func stopClosesConnectionsAndUnlinks() async throws {
        let path = testSocketPath()
        let responder = Box<SocketResponder?>(nil)
        let closes = Box(0)
        let server = SocketServer(path: path) { _, r in
            r.onClose = { closes.mutate { $0 += 1 } }
            responder.value = r
        }
        try server.start()
        defer { unlink(path) }

        let line = try requestLine()
        async let pending = exchangeInBackground(path: path, line: line)
        #expect(await eventually { responder.value != nil })
        server.stop()
        let result = await pending
        #expect(socketError(result) == .closed)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(throws: SocketError.connectFailed) {
            try SocketClient.exchange(path: path, line: try requestLine())
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(closes.value == 0)
        server.stop() // idempotent
    }
}
