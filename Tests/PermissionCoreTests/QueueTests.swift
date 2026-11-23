import Foundation
import Testing
@testable import PermissionCore

@MainActor
@Suite struct QueueTests {
    func make(_ tool: String = "Bash", suggestions: [JSONValue] = []) throws -> PendingRequest {
        let obj: JSONValue = .object([
            "hook_event_name": .string("PermissionRequest"),
            "session_id": .string("sess-\(UUID().uuidString)"),
            "tool_name": .string(tool),
            "tool_input": .object(["command": .string("ls")]),
            "permission_suggestions": .array(suggestions),
        ])
        return PendingRequest(request: try PermissionRequest(json: JSONEncoder().encode(obj)))
    }

    final class Recorder { var calls: [Decision] = [] }

    func add(_ q: RequestQueue, _ rec: Recorder = Recorder()) throws -> (PendingRequest, Recorder) {
        let p = try make()
        q.add(p) { rec.calls.append($0) }
        return (p, rec)
    }

    @Test func oldestIsFirstAdded() throws {
        let q = RequestQueue()
        #expect(q.oldest == nil)
        let (a, _) = try add(q)
        _ = try add(q)
        #expect(q.oldest?.id == a.id)
        #expect(q.pending.count == 2)
    }

    @Test func resolveCallsRespondOnceAndRemoves() throws {
        let q = RequestQueue()
        let (p, rec) = try add(q)
        #expect(q.resolve(id: p.id, with: .allow) == .allowed)
        #expect(q.resolve(id: p.id, with: .deny(message: "x")) == nil)
        #expect(rec.calls == [.allow])
        #expect(q.pending.isEmpty)
    }

    @Test func resolveMapsOutcomes() throws {
        let q = RequestQueue()
        let cases: [(Decision, HistoryEntry.Outcome)] = [
            (.allow, .allowed),
            (.allowAlways(updatedPermissions: []), .alwaysAllowed),
            (.deny(message: denyMessage), .denied),
            (.pass, .answeredElsewhere),
        ]
        for (d, expected) in cases {
            let (p, rec) = try add(q)
            #expect(q.resolve(id: p.id, with: d) == expected)
            #expect(rec.calls == [d])
        }
    }

    @Test func expireRemovesWithoutResponding() throws {
        let q = RequestQueue()
        let (p, rec) = try add(q)
        #expect(q.expire(id: p.id))
        #expect(!q.expire(id: p.id))
        #expect(rec.calls.isEmpty)
        #expect(q.pending.isEmpty)
        #expect(q.resolve(id: p.id, with: .allow) == nil)
        #expect(rec.calls.isEmpty)
    }

    @Test func expireAfterResolveReturnsFalse() throws {
        let q = RequestQueue()
        let (p, rec) = try add(q)
        _ = q.resolve(id: p.id, with: .allow)
        #expect(!q.expire(id: p.id))
        #expect(rec.calls.count == 1)
    }

    @Test func outOfOrderResolution() throws {
        let q = RequestQueue()
        var items: [(PendingRequest, Recorder)] = []
        for _ in 0..<6 { items.append(try add(q)) }
        _ = q.resolve(id: items[2].0.id, with: .allow)
        _ = q.resolve(id: items[4].0.id, with: .deny(message: "n"))
        let expected = [0, 1, 3, 5].map { items[$0].0.id }
        #expect(q.pending.map(\.id) == expected)
        #expect(q.oldest?.id == items[0].0.id)
        #expect(items.map { $0.1.calls.count } == [0, 0, 1, 0, 1, 0])
    }

    @Test func passAllRespondsPass() throws {
        let q = RequestQueue()
        let (a, ra) = try add(q)
        let (b, rb) = try add(q)
        _ = q.resolve(id: a.id, with: .allow)
        q.passAll()
        #expect(ra.calls == [.allow])
        #expect(rb.calls == [.pass])
        #expect(q.pending.isEmpty)
        _ = b
        q.passAll()
        #expect(rb.calls == [.pass])
    }

    @Test func pendingRequestConvenienceInit() throws {
        let sugg: [JSONValue] = [
            .object(["type": .string("addRules"), "behavior": .string("allow")]),
            .object(["type": .string("setMode"), "mode": .string("x")]),
        ]
        let p = try make(suggestions: sugg)
        #expect(p.alwaysAllowUpdates == [sugg[0]])
        #expect(p.summary.headline == "Claude wants to run a command")
    }
}
