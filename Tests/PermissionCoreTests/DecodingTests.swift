import Foundation
import Testing
@testable import PermissionCore

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct DecodingTests {
    @Test func decodesBashFixture() throws {
        let r = try PermissionRequest(json: fixture("bash"))
        #expect(r.toolName == "Bash")
        #expect(r.toolInput["command"]?.stringValue == "npm install express")
        #expect(r.cwd == "/Users/me/proj")
        #expect(r.permissionSuggestions.count == 2)
    }

    @Test func decodesOtherFixtures() throws {
        let m = try PermissionRequest(json: fixture("mcp"))
        #expect(m.toolName == "mcp__github__create_issue")
        #expect(m.mcpServer == "github")
        _ = try PermissionRequest(json: fixture("edit"))
        let q = try PermissionRequest(json: fixture("ask_user_question"))
        #expect(q.toolInput["questions"]?.arrayValue?.count == 1)
    }

    @Test func rejectsWrongEvent() {
        let d = Data(#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#.utf8)
        #expect(throws: (any Error).self) { try PermissionRequest(json: d) }
    }

    @Test func rejectsMissingToolName() {
        let d = Data(#"{"hook_event_name":"PermissionRequest"}"#.utf8)
        #expect(throws: (any Error).self) { try PermissionRequest(json: d) }
    }

    @Test func rejectsNonJSON() {
        #expect(throws: (any Error).self) { try PermissionRequest(json: Data("hello".utf8)) }
    }

    @Test func defaultsMissingInputAndSuggestions() throws {
        let d = Data(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash"}"#.utf8)
        let r = try PermissionRequest(json: d)
        #expect(r.toolInput == .object([:]))
        #expect(r.permissionSuggestions.isEmpty)
    }

    @Test func compactStringSortsAndTruncates() {
        let v = JSONValue.object(["b": .number(1), "a": .string("x")])
        #expect(v.compactString(maxLength: 100) == #"{"a":"x","b":1}"#)
        #expect(v.compactString(maxLength: 5).count <= 5)
    }
}
