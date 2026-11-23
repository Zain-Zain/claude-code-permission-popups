import Foundation

public let denyMessage = "The user denied this request from the permission popup."

public enum Decision: Equatable, Sendable {
    case allow
    case allowAlways(updatedPermissions: [JSONValue])
    case deny(message: String)
    case pass
}

public enum ClaudeHookOutput {
    /// Hook stdout JSON for a decision, or nil for `.pass` (print nothing, fall through to the normal dialog).
    public static func encode(_ d: Decision) -> Data? {
        let decision: JSONValue
        switch d {
        case .pass:
            return nil
        case .allow:
            decision = .object(["behavior": .string("allow")])
        case .allowAlways(let updates):
            decision = .object(["behavior": .string("allow"), "updatedPermissions": .array(updates)])
        case .deny(let message):
            decision = .object([
                "behavior": .string("deny"),
                "message": .string(message),
                "interrupt": .bool(false),
            ])
        }
        let out = JSONValue.object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": decision,
            ]),
        ])
        return try? JSONEncoder().encode(out)
    }
}

/// Keeps only `addRules` suggestions whose behavior is `allow`.
public func alwaysAllowUpdates(from suggestions: [JSONValue]) -> [JSONValue] {
    suggestions.filter {
        $0["type"]?.stringValue == "addRules" && $0["behavior"]?.stringValue == "allow"
    }
}
