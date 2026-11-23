import Foundation
import Testing
@testable import PermissionCore

private let helper = "/Applications/Permission Popups.app/Contents/MacOS/permission-hook"
private let oldHelper = "/Old/Path/permission-hook"

private func parse(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data)
}

private func parse(_ text: String) throws -> JSONValue {
    try parse(Data(text.utf8))
}

private func data(_ text: String) -> Data { Data(text.utf8) }

private func permissionRequestEntries(_ root: JSONValue) -> [JSONValue] {
    root["hooks"]?["PermissionRequest"]?.arrayValue ?? []
}

@Suite struct HookSettingsTests {
    @Test func entryHasExactShape() throws {
        #expect(HookSettings.entry(helperPath: helper) == .object([
            "matcher": .string("*"),
            "hooks": .array([.object([
                "type": .string("command"),
                "command": .string(helper),
                "timeout": .number(600),
            ])]),
        ]))
    }

    // MARK: Installing

    @Test func installIntoNil() throws {
        let out = try HookSettings.install(into: nil, helperPath: helper)
        #expect(try parse(out) == .object([
            "hooks": .object(["PermissionRequest": .array([HookSettings.entry(helperPath: helper)])]),
        ]))
        #expect(out.last == UInt8(ascii: "\n"))
    }

    @Test func installIntoEmptyOrWhitespaceTreatedAsNil() throws {
        let expected = try HookSettings.install(into: nil, helperPath: helper)
        #expect(try HookSettings.install(into: Data(), helperPath: helper) == expected)
        #expect(try HookSettings.install(into: data("  \n\t "), helperPath: helper) == expected)
    }

    @Test func installPreservesOtherKeys() throws {
        let existing = data("""
        {"permissions":{"allow":["Bash(ls)"]},"cleanupPeriodDays":30,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo hi","timeout":30}]}]}}
        """)
        let before = try parse(existing)
        let after = try parse(HookSettings.install(into: existing, helperPath: helper))
        #expect(after["permissions"] == before["permissions"])
        #expect(after["cleanupPeriodDays"] == .number(30))
        #expect(after["hooks"]?["Stop"] == before["hooks"]?["Stop"])
        #expect(permissionRequestEntries(after) == [HookSettings.entry(helperPath: helper)])
    }

    @Test func installPreservesOtherPermissionRequestHooks() throws {
        let theirs = #"{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/other"}]}"#
        let existing = data(#"{"hooks":{"PermissionRequest":[\#(theirs)]}}"#)
        let entries = permissionRequestEntries(try parse(HookSettings.install(into: existing, helperPath: helper)))
        #expect(entries == [try parse(theirs), HookSettings.entry(helperPath: helper)])
    }

    @Test func installIsIdempotent() throws {
        let once = try HookSettings.install(into: nil, helperPath: helper)
        let twice = try HookSettings.install(into: once, helperPath: helper)
        #expect(twice == once)
        #expect(permissionRequestEntries(try parse(twice)).count == 1)
    }

    @Test func installReplacesMovedApp() throws {
        let old = try HookSettings.install(into: nil, helperPath: oldHelper)
        let out = try parse(HookSettings.install(into: old, helperPath: helper))
        #expect(permissionRequestEntries(out) == [HookSettings.entry(helperPath: helper)])
    }

    @Test func installReplacesInPlaceAndKeepsOrder() throws {
        let a = #"{"matcher":"A","hooks":[{"type":"command","command":"/a"}]}"#
        let b = #"{"matcher":"B","hooks":[{"type":"command","command":"/b"}]}"#
        let ours = #"{"matcher":"*","hooks":[{"type":"command","command":"\#(oldHelper)","timeout":600}]}"#
        let existing = data(#"{"hooks":{"PermissionRequest":[\#(a),\#(ours),\#(b)]}}"#)
        let entries = permissionRequestEntries(try parse(HookSettings.install(into: existing, helperPath: helper)))
        #expect(entries == [try parse(a), HookSettings.entry(helperPath: helper), try parse(b)])
    }

    @Test func installKeepsOtherHooksSharingOurEntry() throws {
        let mixed = data("""
        {"hooks":{"PermissionRequest":[{"matcher":"X","hooks":[
          {"type":"command","command":"/Old/Path/permission-hook"},
          {"type":"command","command":"/usr/bin/keep-me"}]}]}}
        """)
        let entries = permissionRequestEntries(try parse(HookSettings.install(into: mixed, helperPath: helper)))
        #expect(entries.count == 2)
        #expect(entries[0] == (try parse(#"{"matcher":"X","hooks":[{"type":"command","command":"/usr/bin/keep-me"}]}"#)))
        #expect(entries[1] == HookSettings.entry(helperPath: helper))
    }

    @Test func nonObjectEntriesArePreservedAndNotOurs() throws {
        let existing = data(#"{"hooks":{"PermissionRequest":["junk",7,null,{"hooks":"nope"},{"hooks":[1,{"command":5}]}]}}"#)
        #expect(HookSettings.status(of: existing, helperPath: helper) == .notInstalled)
        let entries = permissionRequestEntries(try parse(HookSettings.install(into: existing, helperPath: helper)))
        #expect(entries.count == 6)
        #expect(entries[0] == .string("junk"))
        #expect(entries[1] == .number(7))
        #expect(entries[2] == .null)
        #expect(entries[5] == HookSettings.entry(helperPath: helper))
        let removed = permissionRequestEntries(try parse(HookSettings.uninstall(from: existing, helperPath: helper)))
        #expect(removed.count == 5)
    }

    @Test func matchesQuotedAndPaddedCommands() throws {
        for cmd in [#""/x y/permission-hook""#, "'/x/permission-hook'", "  /x/permission-hook  ", "permission-hook"] {
            let json = try JSONEncoder().encode(JSONValue.object(["hooks": .object(["PermissionRequest": .array([
                .object(["hooks": .array([.object(["command": .string(cmd)])])]),
            ])])]))
            #expect(HookSettings.status(of: json, helperPath: helper) != .notInstalled, "\(cmd)")
        }
        for cmd in ["/x/permission-hook-extra", "/x/my-permission-hook", "/x/permission-hook/sub"] {
            let json = try JSONEncoder().encode(JSONValue.object(["hooks": .object(["PermissionRequest": .array([
                .object(["hooks": .array([.object(["command": .string(cmd)])])]),
            ])])]))
            #expect(HookSettings.status(of: json, helperPath: helper) == .notInstalled, "\(cmd)")
        }
    }

    // MARK: Bad files

    @Test func invalidJSONThrows() {
        #expect(throws: HookSettingsError.invalidJSON) {
            try HookSettings.install(into: data("{ // comment"), helperPath: helper)
        }
        #expect(throws: HookSettingsError.invalidJSON) {
            try HookSettings.uninstall(from: data("{ // comment"), helperPath: helper)
        }
    }

    @Test func nonObjectHooksThrows() {
        for text in [#"{"hooks":[]}"#, #"{"hooks":null}"#, #"{"hooks":"x"}"#] {
            #expect(throws: HookSettingsError.self) {
                try HookSettings.install(into: data(text), helperPath: helper)
            }
        }
    }

    @Test func nonArrayPermissionRequestThrowsUnexpectedShape() {
        for text in [#"{"hooks":{"PermissionRequest":{}}}"#, #"{"hooks":{"PermissionRequest":null}}"#] {
            do {
                _ = try HookSettings.install(into: data(text), helperPath: helper)
                Issue.record("expected throw for \(text)")
            } catch let HookSettingsError.unexpectedShape(msg) {
                #expect(!msg.isEmpty)
            } catch {
                Issue.record("wrong error \(error)")
            }
        }
    }

    @Test func nonObjectTopLevelThrowsUnexpectedShape() {
        for text in ["[]", "7", "\"s\"", "null"] {
            do {
                _ = try HookSettings.install(into: data(text), helperPath: helper)
                Issue.record("expected throw for \(text)")
            } catch HookSettingsError.unexpectedShape {
            } catch {
                Issue.record("wrong error \(error) for \(text)")
            }
        }
    }

    // MARK: Uninstalling and status

    @Test func uninstallRemovesOnlyOurs() throws {
        let theirs = #"{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/other"}]}"#
        let ours = HookSettings.entry(helperPath: helper)
        let ourJSON = String(data: try JSONEncoder().encode(ours), encoding: .utf8)!
        let existing = data(#"{"x":1,"hooks":{"Stop":[{"hooks":[]}],"PermissionRequest":[\#(theirs),\#(ourJSON)]}}"#)
        let out = try parse(HookSettings.uninstall(from: existing, helperPath: helper))
        #expect(permissionRequestEntries(out) == [try parse(theirs)])
        #expect(out["x"] == .number(1))
        #expect(out["hooks"]?["Stop"] != nil)
    }

    @Test func uninstallPrunesEmptyContainers() throws {
        let installed = try HookSettings.install(into: data(#"{"keep":true}"#), helperPath: helper)
        let out = try parse(HookSettings.uninstall(from: installed, helperPath: helper))
        #expect(out == .object(["keep": .bool(true)]))

        let withStop = try HookSettings.install(into: data(#"{"hooks":{"Stop":[]}}"#), helperPath: helper)
        let out2 = try parse(HookSettings.uninstall(from: withStop, helperPath: helper))
        #expect(out2 == .object(["hooks": .object(["Stop": .array([])])]))
    }

    @Test func uninstallWhenNotInstalledKeepsMeaning() throws {
        let existing = data(#"{"a":[1,2],"hooks":{}}"#)
        #expect(try parse(HookSettings.uninstall(from: existing, helperPath: helper)) == (try parse(existing)))
        #expect(try HookSettings.uninstall(from: Data(), helperPath: helper) == Data())
    }

    @Test func statusReports() throws {
        #expect(HookSettings.status(of: nil, helperPath: helper) == .notInstalled)
        #expect(HookSettings.status(of: data("{}"), helperPath: helper) == .notInstalled)
        let here = try HookSettings.install(into: nil, helperPath: helper)
        #expect(HookSettings.status(of: here, helperPath: helper) == .installed)
        let old = try HookSettings.install(into: nil, helperPath: oldHelper)
        #expect(HookSettings.status(of: old, helperPath: helper) == .installedAtOtherPath(oldHelper))
    }

    @Test func statusOnBadFilesIsNotInstalled() {
        for text in ["{ // comment", "[]", #"{"hooks":[]}"#, #"{"hooks":{"PermissionRequest":{}}}"#, ""] {
            #expect(HookSettings.status(of: data(text), helperPath: helper) == .notInstalled, "\(text)")
        }
    }

    // MARK: Output format

    @Test func outputIsPrettySortedUnescapedWithTrailingNewline() throws {
        let out = try HookSettings.install(into: data(#"{"z":1,"a":2}"#), helperPath: helper)
        let text = String(data: out, encoding: .utf8)!
        #expect(text.hasSuffix("}\n"))
        #expect(!text.hasSuffix("\n\n"))
        #expect(text.contains("\n  \"a\""))
        #expect(text.firstRange(of: "\"a\"")!.lowerBound < text.firstRange(of: "\"hooks\"")!.lowerBound)
        #expect(text.firstRange(of: "\"hooks\"")!.lowerBound < text.firstRange(of: "\"z\"")!.lowerBound)
        #expect(!text.contains("\\/"))
        #expect(text.contains(helper))
    }

    @Test func integersSurviveRoundTrip() throws {
        let existing = data(#"{"cleanupPeriodDays":30,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x","timeout":30}]}]}}"#)
        let text = String(data: try HookSettings.install(into: existing, helperPath: helper), encoding: .utf8)!
        #expect(text.contains("\"cleanupPeriodDays\" : 30\n") || text.contains("\"cleanupPeriodDays\" : 30,"))
        #expect(text.contains("\"timeout\" : 30"))
        #expect(text.contains("\"timeout\" : 600"))
        #expect(!text.contains("30.0"))
        #expect(!text.contains("600.0"))
    }

    @Test func integralNumbersEncodeWithoutFraction() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let v = JSONValue.array([.number(600), .number(0), .number(-3), .number(1.5), .number(9_007_199_254_740_992)])
        let text = String(data: try enc.encode(v), encoding: .utf8)!
        #expect(text == "[600,0,-3,1.5,9007199254740992]")
    }
}
