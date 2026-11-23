import Foundation

public enum SocketError: Error, Equatable {
    /// The path does not fit in `sockaddr_un.sun_path` (104 bytes including the NUL).
    case pathTooLong
    /// No server: the socket file is missing, refuses connections, or is not accessible.
    case connectFailed
    /// The connection ended (EOF or I/O error) before a complete line arrived.
    case closed
    /// `start()` was called on a server that is already running or was stopped.
    case alreadyStarted
    /// A setup system call failed.
    case system(call: String, errno: Int32)
}

/// Low-level helpers shared by `SocketServer` and `SocketClient` (and the app's
/// single-instance probe, which uses `connect`).
public enum UnixSocket {
    static let maxPathBytes = 104

    /// Calls `body` with a `sockaddr_un` for `path`.
    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        let bytes = Array(path.utf8)
        guard bytes.count < maxPathBytes, !bytes.contains(0) else { throw SocketError.pathTooLong }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes) // remaining bytes are already zero
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Sets FD_CLOEXEC and SO_NOSIGPIPE, and optionally O_NONBLOCK.
    static func configure(_ fd: Int32, nonBlocking: Bool) {
        _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setNonBlocking(fd, nonBlocking)
    }

    static func setNonBlocking(_ fd: Int32, _ on: Bool) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, on ? flags | O_NONBLOCK : flags & ~O_NONBLOCK)
    }

    /// Opens a blocking client socket connected to `path`. The caller closes it.
    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system(call: "socket", errno: errno) }
        configure(fd, nonBlocking: false)
        let rc: Int32
        do {
            rc = try withAddress(path) { Darwin.connect(fd, $0, $1) }
        } catch {
            close(fd)
            throw error
        }
        guard rc == 0 else {
            close(fd)
            throw SocketError.connectFailed
        }
        return fd
    }

    /// Writes all of `data` to a blocking fd. Returns false on any error.
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
