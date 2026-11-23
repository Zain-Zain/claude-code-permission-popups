import Foundation

/// App-side Unix socket server. One connection carries one request.
///
/// Threading: accepting and all per-connection I/O happen on background queues.
/// `onRequest` and `SocketResponder.onClose` are always called on the main queue.
public final class SocketServer {
    /// Longest accepted request line, excluding the "\n".
    static let maxLineBytes = 8 * 1024 * 1024

    /// How long a new connection may take to send its request line. Set before `start()`.
    var firstLineTimeout: TimeInterval = 10
    /// Only peers running as this UID are served. Set before `start()`; tests override it.
    var allowedUID: uid_t = getuid()

    private let path: String
    private let onRequest: (WireRequest, SocketResponder) -> Void
    private let acceptQueue = DispatchQueue(label: "local.permission-popups.socket.accept")

    private enum State { case idle, running, stopped }
    private let lock = NSLock()
    private var state = State.idle
    private var listenSource: DispatchSourceRead?
    /// True while the listen source is suspended for accept back-off. Guarded by `lock`.
    private var listenSuspended = false
    private var boundFile: (dev: dev_t, ino: ino_t)?
    private var connections: [UUID: SocketResponder] = [:]

    public init(path: String, onRequest: @escaping (WireRequest, SocketResponder) -> Void) {
        self.path = path
        self.onRequest = onRequest
    }

    deinit { stop() }

    /// Removes any stale file at the path, binds with mode 0600, and starts accepting.
    public func start() throws {
        guard path.utf8.count < UnixSocket.maxPathBytes else { throw SocketError.pathTooLong }
        lock.lock()
        defer { lock.unlock() }
        guard state == .idle else { throw SocketError.alreadyStarted }

        // A file left behind by a crashed instance refuses connections; replace it.
        if unlink(path) != 0 && errno != ENOENT {
            throw SocketError.system(call: "unlink", errno: errno)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system(call: "socket", errno: errno) }
        UnixSocket.configure(fd, nonBlocking: true)

        func fail(_ call: String, unlinkFile: Bool) -> SocketError {
            let code = errno
            close(fd)
            if unlinkFile { unlink(path) }
            return SocketError.system(call: call, errno: code)
        }
        let bound: Int32
        do {
            bound = try UnixSocket.withAddress(path) { bind(fd, $0, $1) }
        } catch {
            close(fd)
            throw error
        }
        guard bound == 0 else { throw fail("bind", unlinkFile: false) }
        // The window between bind and chmod is covered by the 0700 directory and the peer UID check.
        guard chmod(path, 0o600) == 0 else { throw fail("chmod", unlinkFile: true) }
        var st = stat()
        guard lstat(path, &st) == 0 else { throw fail("lstat", unlinkFile: true) }
        guard listen(fd, SOMAXCONN) == 0 else { throw fail("listen", unlinkFile: true) }

        let uid = allowedUID
        let timeout = firstLineTimeout
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPending(listenFD: fd, allowedUID: uid, firstLineTimeout: timeout)
        }
        source.setCancelHandler { close(fd) }
        listenSource = source
        boundFile = (st.st_dev, st.st_ino)
        state = .running
        source.resume()
    }

    /// Closes the listening socket and every open connection (peers see EOF), then removes
    /// the socket file. `onClose` is not called for connections closed this way. Idempotent.
    public func stop() {
        lock.lock()
        let source = listenSource
        let wasSuspended = listenSuspended
        listenSuspended = false
        let open = Array(connections.values)
        let file = boundFile
        listenSource = nil
        boundFile = nil
        connections = [:]
        state = .stopped
        lock.unlock()

        // A suspended source cannot be cancelled cleanly: resume it first.
        if wasSuspended { source?.resume() }
        source?.cancel()
        for connection in open { connection.forceClose() }
        // Only remove the file if it is still the one we bound (not a newer instance's socket).
        var st = stat()
        if let file, lstat(path, &st) == 0, st.st_dev == file.dev, st.st_ino == file.ino {
            unlink(path)
        }
    }

    // Runs on acceptQueue.
    private func acceptPending(listenFD: Int32, allowedUID: uid_t, firstLineTimeout: TimeInterval) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                if errno == EMFILE || errno == ENFILE || errno == ENOBUFS {
                    backOffAccepting()
                }
                return // EAGAIN: drained. Anything else: retry on the next event.
            }
            UnixSocket.configure(fd, nonBlocking: true)

            var uid = uid_t.max
            var gid = gid_t.max
            guard getpeereid(fd, &uid, &gid) == 0, uid == allowedUID else {
                close(fd)
                continue
            }

            let connection = SocketResponder(
                fd: fd,
                firstLineTimeout: firstLineTimeout,
                deliver: { [weak self] request, responder in
                    DispatchQueue.main.async {
                        guard let self, self.isRunning else { return }
                        self.onRequest(request, responder)
                    }
                },
                finished: { [weak self] id in self?.remove(id) }
            )
            lock.lock()
            guard state == .running else {
                lock.unlock()
                close(fd)
                return
            }
            connections[connection.id] = connection
            lock.unlock()
            connection.begin()
        }
    }

    /// Out of descriptors or buffers: the level-triggered listen source would re-fire at once
    /// and spin. Pause it and resume shortly, unless `stop()` ran in between.
    private func backOffAccepting() {
        lock.lock()
        guard state == .running, !listenSuspended, let source = listenSource else {
            lock.unlock()
            return
        }
        listenSuspended = true
        source.suspend()
        lock.unlock()
        acceptQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.listenSuspended, self.state == .running, let source = self.listenSource else { return }
            self.listenSuspended = false
            source.resume()
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .running
    }

    private func remove(_ id: UUID) {
        lock.lock()
        connections[id] = nil
        lock.unlock()
    }
}

/// One accepted connection. Handed to `onRequest`; answer it with `reply` exactly once.
public final class SocketResponder {
    enum Outcome: Equatable {
        /// Still reading the request line, or waiting for `reply`.
        case pending
        /// The reply was written to the peer and the connection closed.
        case replied
        /// The peer disconnected after its request was delivered; `onClose` fires.
        case peerClosed
        /// Closed without callbacks: bad or missing request line, timeout, or `stop()`.
        case dropped
    }

    public let id = UUID()
    /// Called on the main queue if the peer disconnects before `reply` writes.
    /// Set it on the main queue, from inside `onRequest`.
    public var onClose: (() -> Void)?

    private let fd: Int32
    private let queue = DispatchQueue(label: "local.permission-popups.socket.connection",
                                      target: .global(qos: .userInitiated))
    private let firstLineTimeout: TimeInterval
    private let deliver: (WireRequest, SocketResponder) -> Void
    private let finished: (UUID) -> Void

    // Confined to `queue`.
    private var readSource: DispatchSourceRead?
    private var lineTimer: DispatchSourceTimer?
    private var line = Data()
    private var delivered = false
    private var state = Outcome.pending

    init(fd: Int32,
         firstLineTimeout: TimeInterval,
         deliver: @escaping (WireRequest, SocketResponder) -> Void,
         finished: @escaping (UUID) -> Void) {
        self.fd = fd
        self.firstLineTimeout = firstLineTimeout
        self.deliver = deliver
        self.finished = finished
    }

    var outcome: Outcome { queue.sync { state } }

    /// Writes the reply as one JSON line, then closes the connection. Later calls do nothing.
    /// If the peer has already gone, nothing is written and `onClose` fires instead.
    public func reply(_ r: WireReply) {
        queue.async { self.writeReply(r) }
    }

    func begin() {
        queue.async {
            guard self.state == .pending else { return } // stopped before we started
            let source = DispatchSource.makeReadSource(fileDescriptor: self.fd, queue: self.queue)
            let fd = self.fd
            source.setEventHandler { self.handleReadable() }
            source.setCancelHandler { close(fd) }
            self.readSource = source

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.firstLineTimeout)
            timer.setEventHandler {
                if !self.delivered { self.finish(.dropped) }
            }
            self.lineTimer = timer

            source.resume()
            timer.resume()
        }
    }

    /// Used by `SocketServer.stop()`: close now, without callbacks.
    func forceClose() {
        queue.sync { finish(.dropped) }
    }

    // MARK: - Queue-confined

    private func handleReadable() {
        guard state == .pending else { return }
        if delivered { watchForEOF() } else { readRequestLine() }
    }

    /// Reads up to and including the first "\n", never past it: each chunk is peeked,
    /// and only the bytes up to the newline are consumed.
    private func readRequestLine() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let peeked = recv(fd, &chunk, chunk.count, MSG_PEEK)
            if peeked == 0 { return finish(.dropped) } // EOF before a full line
            if peeked < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { return }
                return finish(.dropped)
            }
            let newline = chunk[0..<peeked].firstIndex(of: 0x0A)
            let take = newline.map { $0 + 1 } ?? peeked
            guard recv(fd, &chunk, take, 0) == take else { return finish(.dropped) }

            line.append(contentsOf: chunk[0..<(newline ?? take)])
            if line.count > SocketServer.maxLineBytes { return finish(.dropped) }
            if newline != nil { return handleLine() }
        }
    }

    private func handleLine() {
        lineTimer?.cancel()
        lineTimer = nil
        let data = line
        line = Data()
        guard let request = try? JSONDecoder().decode(WireRequest.self, from: data) else {
            return finish(.dropped)
        }
        delivered = true
        deliver(request, self)
    }

    /// After the request: the helper sends nothing more, so a 0-byte read means it went away.
    /// Stray bytes are discarded one chunk per event so a chatty peer cannot pin the queue.
    private func watchForEOF() {
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &scratch, scratch.count)
            if n > 0 { return }
            if n == 0 { return finish(.peerClosed) }
            if errno == EINTR { continue }
            if errno == EAGAIN { return }
            return finish(.peerClosed)
        }
    }

    private func writeReply(_ r: WireReply) {
        guard state == .pending, delivered else { return }
        guard var data = try? JSONEncoder().encode(r) else { return finish(.dropped) }
        data.append(0x0A)
        // Write in blocking mode with a bound, so a full buffer cannot wedge this queue forever.
        UnixSocket.setNonBlocking(fd, false)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        finish(UnixSocket.writeAll(fd, data) ? .replied : .peerClosed)
    }

    /// The single exit point: runs at most once, closes the fd exactly once.
    private func finish(_ outcome: Outcome) {
        guard state == .pending else { return }
        state = outcome
        lineTimer?.cancel()
        lineTimer = nil
        line = Data()
        _ = shutdown(fd, SHUT_RDWR) // peer sees EOF now, even before the fd is closed
        if let source = readSource {
            source.cancel() // its cancel handler closes the fd
        } else {
            close(fd)
        }
        finished(id)
        // onClose is set and cleared on main. Clearing it breaks retain cycles through captures.
        DispatchQueue.main.async {
            let callback = self.onClose
            self.onClose = nil
            if outcome == .peerClosed { callback?() }
        }
    }
}
