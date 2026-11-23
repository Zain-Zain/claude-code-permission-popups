import Foundation

/// Helper-side, blocking, one-shot exchange: send one line, wait for one line back.
public enum SocketClient {
    /// Replies longer than this are treated as a broken connection.
    static let maxReplyBytes = 8 * 1024 * 1024

    /// Connects to `path`, writes `line` + "\n", then blocks until the server sends a line
    /// or closes the connection. Returns the bytes before the first "\n".
    ///
    /// Throws `.connectFailed` when no server is listening (missing file, ECONNREFUSED),
    /// `.pathTooLong` for an unusable path, and `.closed` when the connection ends or
    /// fails before a full line arrives. The write side is never shut down early, because
    /// the server treats EOF from the helper as "the request was withdrawn".
    public static func exchange(path: String, line: Data) throws -> Data {
        let fd = try UnixSocket.connect(path: path)
        defer { close(fd) }

        var out = line
        out.append(0x0A)
        guard UnixSocket.writeAll(fd, out) else { throw SocketError.closed }

        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                if let newline = chunk[0..<n].firstIndex(of: 0x0A) {
                    received.append(contentsOf: chunk[0..<newline])
                    return received
                }
                received.append(contentsOf: chunk[0..<n])
                if received.count > maxReplyBytes { throw SocketError.closed }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                throw SocketError.closed
            }
        }
    }
}
