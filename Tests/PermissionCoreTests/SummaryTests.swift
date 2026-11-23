import Foundation
import Testing
@testable import PermissionCore

@Suite struct SummaryTests {
    func make(_ tool: String, _ input: JSONValue, suggestions: [JSONValue] = [], mcp: String? = nil) throws -> RequestSummary {
        var obj: [String: JSONValue] = [
            "hook_event_name": .string("PermissionRequest"),
            "tool_name": .string(tool),
            "tool_input": input,
            "cwd": .string("/Users/me/proj"),
            "permission_suggestions": .array(suggestions),
        ]
        if let mcp { obj["mcp_server"] = .string(mcp) }
        let data = try JSONEncoder().encode(JSONValue.object(obj))
        return RequestSummary(try PermissionRequest(json: data), homeDirectory: "/Users/me")
    }

    func s(_ v: String) -> JSONValue { .string(v) }

    @Test func bashSummary() throws {
        let r = try PermissionRequest(json: fixture("bash"))
        let sum = RequestSummary(r, homeDirectory: "/Users/me")
        #expect(sum.headline == "Claude wants to run a command")
        #expect(sum.primary == "npm install express")
        #expect(sum.detail == "Install express")
        #expect(sum.cwd == "~/proj")
        #expect(sum.alwaysAllowRules == ["Bash(npm install:*) — this project"])
    }

    @Test func editSummary() throws {
        let long = String(repeating: "a", count: 500)
        let sum = try make("Edit", .object(["file_path": s("/x/main.swift"), "old_string": s(long), "new_string": s("bar")]))
        #expect(sum.headline == "Claude wants to edit a file")
        #expect(sum.primary == "/x/main.swift")
        let detail = try #require(sum.detail)
        #expect(detail.hasPrefix("−"))
        let lines = detail.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].count <= 202)
        #expect(lines[1] == "+ bar")
        let small = try make("Edit", .object(["file_path": s("/x"), "old_string": s("foo"), "new_string": s("bar")]))
        #expect(small.detail == "− foo\n+ bar")
        let multi = try make("MultiEdit", .object(["file_path": s("/x"), "edits": .array([.object(["old_string": s("a"), "new_string": s("b")])])]))
        #expect(multi.headline == "Claude wants to edit a file")
        #expect(multi.detail == "− a\n+ b")
    }

    @Test func writeSummary() throws {
        let sum = try make("Write", .object(["file_path": s("/x/a.txt"), "content": s("hi")]))
        #expect(sum.headline == "Claude wants to create a file")
        #expect(sum.primary == "/x/a.txt")
    }

    @Test func readSummary() throws {
        let sum = try make("Read", .object(["file_path": s("/x/a.txt")]))
        #expect(sum.headline == "Claude wants to read a file")
        #expect(sum.primary == "/x/a.txt")
    }

    @Test func grepSummary() throws {
        for tool in ["Grep", "Glob"] {
            let sum = try make(tool, .object(["pattern": s("foo.*")]))
            #expect(sum.headline == "Claude wants to search files")
            #expect(sum.primary == "foo.*")
        }
    }

    @Test func webFetchSummary() throws {
        let sum = try make("WebFetch", .object(["url": s("https://example.com")]))
        #expect(sum.headline == "Claude wants to fetch a web page")
        #expect(sum.primary == "https://example.com")
    }

    @Test func webSearchSummary() throws {
        let sum = try make("WebSearch", .object(["query": s("swift testing")]))
        #expect(sum.headline == "Claude wants to search the web")
        #expect(sum.primary == "swift testing")
    }

    @Test func mcpSummary() throws {
        let r = try PermissionRequest(json: fixture("mcp"))
        let sum = RequestSummary(r, homeDirectory: "/Users/me")
        #expect(sum.headline == "Claude wants to use create_issue from github")
        #expect(sum.primary == #"{"body":"Something broke","title":"Bug"}"#)
        #expect(sum.alwaysAllowRules == ["mcp__github__create_issue — this project"])
    }

    @Test func exitPlanSummary() throws {
        let plan = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let sum = try make("ExitPlanMode", .object(["plan": s(plan)]))
        #expect(sum.headline == "Claude wants to approve its plan")
        #expect(sum.primary == (1...6).map { "line \($0)" }.joined(separator: "\n"))
    }

    @Test func unknownToolSummary() throws {
        let sum = try make("Foo", .object(["a": .number(1)]))
        #expect(sum.headline == "Claude wants to use Foo")
        #expect(sum.primary == #"{"a":1}"#)
    }

    @Test func capsHugePrimary() throws {
        let sum = try make("Bash", .object(["command": s(String(repeating: "x", count: 10_000))]))
        let p = try #require(sum.primary)
        #expect(p.count <= 2001)
        #expect(p.hasSuffix("…"))
        let mcp = try make("mcp__a__b", .object(["k": s(String(repeating: "y", count: 10_000))]), mcp: "a")
        #expect(try #require(mcp.primary).count <= 2001)
    }

    func ruleSummary(_ destination: String) throws -> [String] {
        let sug = JSONValue.object([
            "type": s("addRules"), "behavior": s("allow"), "destination": s(destination),
            "rules": .array([.object(["toolName": s("Bash"), "ruleContent": s("ls")])]),
        ])
        return try make("Bash", .object(["command": s("ls")]), suggestions: [sug]).alwaysAllowRules
    }

    @Test func destinationLabels() throws {
        #expect(try ruleSummary("localSettings") == ["Bash(ls) — this project"])
        #expect(try ruleSummary("projectSettings") == ["Bash(ls) — this project"])
        #expect(try ruleSummary("userSettings") == ["Bash(ls) — all projects"])
        #expect(try ruleSummary("session") == ["Bash(ls) — this session"])
    }

    @Test func ruleWithoutContent() throws {
        let sug = JSONValue.object([
            "type": s("addRules"), "behavior": s("allow"), "destination": s("localSettings"),
            "rules": .array([.object(["toolName": s("WebSearch")])]),
        ])
        let sum = try make("WebSearch", .object(["query": s("q")]), suggestions: [sug])
        #expect(sum.alwaysAllowRules == ["WebSearch — this project"])
    }
}
