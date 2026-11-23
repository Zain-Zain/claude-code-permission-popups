import Foundation

/// The helper's whole decision flow, minus process I/O. It never decides anything itself.
public enum HookRunner {
    /// Tools the popup never answers. `AskUserQuestion` is not a permission decision, and
    /// `ExitPlanMode` needs `updatedInput` on allow, which only Claude's own dialog supplies.
    static let skippedTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Returns the bytes to print on stdout, or nil for "print nothing" (Claude Code then
    /// shows its own prompt). Every failure path returns nil.
    public static func run(stdin: Data, socketPath: String) -> Data? {
        guard let request = try? PermissionRequest(json: stdin) else { return nil }
        if skippedTools.contains(request.toolName) { return nil }
        // Forward exactly what Claude Code sent.
        guard let line = try? JSONEncoder().encode(WireRequest(request: request.raw)) else { return nil }
        guard let replyData = try? SocketClient.exchange(path: socketPath, line: line) else { return nil }
        guard let reply = try? JSONDecoder().decode(WireReply.self, from: replyData),
              let decision = reply.toDecision() else { return nil }
        return ClaudeHookOutput.encode(decision)
    }
}
