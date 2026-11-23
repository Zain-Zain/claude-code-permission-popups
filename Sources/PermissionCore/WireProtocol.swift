import Foundation

public struct WireRequest: Codable {
    public let v: Int
    public let request: JSONValue

    public init(v: Int = 1, request: JSONValue) {
        self.v = v
        self.request = request
    }
}

public struct WireReply: Codable, Equatable {
    public let v: Int
    public let decision: String
    public let updatedPermissions: [JSONValue]?
    public let message: String?

    public init(v: Int, decision: String, updatedPermissions: [JSONValue]?, message: String?) {
        self.v = v
        self.decision = decision
        self.updatedPermissions = updatedPermissions
        self.message = message
    }

    public init(_ d: Decision) {
        switch d {
        case .allow:
            self.init(v: 1, decision: "allow", updatedPermissions: nil, message: nil)
        case .allowAlways(let u):
            self.init(v: 1, decision: "allow_always", updatedPermissions: u, message: nil)
        case .deny(let m):
            self.init(v: 1, decision: "deny", updatedPermissions: nil, message: m)
        case .pass:
            self.init(v: 1, decision: "pass", updatedPermissions: nil, message: nil)
        }
    }

    public func toDecision() -> Decision? {
        switch decision {
        case "allow": return .allow
        case "allow_always":
            guard let updates = updatedPermissions else { return nil }
            return .allowAlways(updatedPermissions: updates)
        case "deny": return .deny(message: message ?? denyMessage)
        case "pass": return .pass
        default: return nil
        }
    }
}
