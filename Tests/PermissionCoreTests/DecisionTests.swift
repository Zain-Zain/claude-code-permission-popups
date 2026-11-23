import Foundation
import Testing
@testable import PermissionCore

private func decisionObject(_ d: Decision) throws -> JSONValue {
    let data = try #require(ClaudeHookOutput.encode(d))
    let top = try JSONDecoder().decode(JSONValue.self, from: data)
    let hso = try #require(top["hookSpecificOutput"])
    #expect(hso["hookEventName"] == .string("PermissionRequest"))
    return try #require(hso["decision"])
}

@Suite struct DecisionTests {
    @Test func encodesAllow() throws {
        #expect(try decisionObject(.allow) == .object(["behavior": .string("allow")]))
    }

    @Test func encodesDeny() throws {
        #expect(try decisionObject(.deny(message: denyMessage)) == .object([
            "behavior": .string("deny"),
            "message": .string(denyMessage),
            "interrupt": .bool(false),
        ]))
    }

    @Test func encodesAllowAlways() throws {
        let r = try PermissionRequest(json: fixture("bash"))
        let entry = r.permissionSuggestions[0]
        #expect(try decisionObject(.allowAlways(updatedPermissions: [entry])) == .object([
            "behavior": .string("allow"),
            "updatedPermissions": .array([entry]),
        ]))
    }

    @Test func passEncodesNil() {
        #expect(ClaudeHookOutput.encode(.pass) == nil)
    }

    @Test func filtersSuggestions() throws {
        let r = try PermissionRequest(json: fixture("bash"))
        #expect(alwaysAllowUpdates(from: r.permissionSuggestions) == [r.permissionSuggestions[0]])
        #expect(alwaysAllowUpdates(from: [r.permissionSuggestions[1]]) == [])
        let deny = JSONValue.object(["type": .string("addRules"), "behavior": .string("deny")])
        #expect(alwaysAllowUpdates(from: [deny]) == [])
    }

    @Test func wireRoundTrip() throws {
        let entry = JSONValue.object(["type": .string("addRules")])
        let all: [Decision] = [.allow, .allowAlways(updatedPermissions: [entry]), .deny(message: "no"), .pass]
        for d in all {
            let data = try JSONEncoder().encode(WireReply(d))
            let back = try JSONDecoder().decode(WireReply.self, from: data)
            #expect(back.toDecision() == d)
        }
        #expect(WireReply(v: 1, decision: "bogus", updatedPermissions: nil, message: nil).toDecision() == nil)
    }
}
