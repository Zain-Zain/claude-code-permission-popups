import Foundation
import PermissionCore

// Exiting closes the socket, which the app sees as the request being withdrawn.
// Only async-signal-safe calls are allowed in a handler.
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig) { _ in _exit(0) }
}
signal(SIGPIPE, SIG_IGN)

#if DEBUG
// Debug builds only (tests and scripts/integration-test.sh). Release builds, including the
// app bundle, always use the socket in the 0700 support directory.
let socketPath = ProcessInfo.processInfo.environment["PERMISSION_POPUPS_SOCKET"] ?? AppPaths.socketPath
#else
let socketPath = AppPaths.socketPath
#endif
let input = (try? FileHandle.standardInput.readToEnd()) ?? Data()
if let output = HookRunner.run(stdin: input, socketPath: socketPath) {
    // The throwing API: the old write(_:) raises an uncatchable exception on I/O errors.
    try? FileHandle.standardOutput.write(contentsOf: output)
}
exit(0)
