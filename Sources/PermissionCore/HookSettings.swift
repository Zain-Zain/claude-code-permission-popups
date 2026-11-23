import Foundation

public enum HookStatus: Equatable {
    case notInstalled
    case installed
    case installedAtOtherPath(String)
}

public enum HookSettingsError: Error, Equatable {
    case invalidJSON
    case unexpectedShape(String)
}

/// Pure Data-in/Data-out editing of the `PermissionRequest` hook in a Claude Code settings.json.
/// Everything that is not our own hook is preserved with identical meaning.
public enum HookSettings {
    public static let timeout = 600
    static let helperName = "permission-hook"

    public static func entry(helperPath: String) -> JSONValue {
        .object([
            "matcher": .string("*"),
            "hooks": .array([.object([
                "type": .string("command"),
                "command": .string(helperPath),
                "timeout": .number(Double(timeout)),
            ])]),
        ])
    }

    public static func install(into existing: Data?, helperPath: String) throws -> Data {
        var root = try parseRoot(existing)
        var hooks = try hooksObject(root)
        var entries = try permissionRequestEntries(hooks)

        let newEntry = entry(helperPath: helperPath)
        var insertAt: Int?
        var kept: [JSONValue] = []
        for e in entries {
            let (remaining, touched) = strippingOurs(e)
            if touched, insertAt == nil, remaining == nil { insertAt = kept.count }
            if let remaining { kept.append(remaining) }
        }
        entries = kept
        entries.insert(newEntry, at: insertAt ?? entries.count)

        hooks["PermissionRequest"] = .array(entries)
        root["hooks"] = .object(hooks)
        return try encode(.object(root))
    }

    public static func uninstall(from existing: Data, helperPath: String) throws -> Data {
        guard !isBlank(existing) else { return existing }
        var root = try parseRoot(existing)
        guard root["hooks"] != nil else { return try encode(.object(root)) }
        var hooks = try hooksObject(root)
        guard hooks["PermissionRequest"] != nil else { return try encode(.object(root)) }
        let entries = try permissionRequestEntries(hooks)

        let kept = entries.compactMap { strippingOurs($0).remaining }
        if kept.isEmpty {
            hooks["PermissionRequest"] = nil
        } else {
            hooks["PermissionRequest"] = .array(kept)
        }
        root["hooks"] = hooks.isEmpty ? nil : .object(hooks)
        return try encode(.object(root))
    }

    public static func status(of existing: Data?, helperPath: String) -> HookStatus {
        guard let root = try? parseRoot(existing),
              let hooks = try? hooksObject(root),
              let entries = try? permissionRequestEntries(hooks) else { return .notInstalled }
        var other: String?
        for e in entries {
            for command in ourCommands(in: e) {
                if command == helperPath { return .installed }
                if other == nil { other = command }
            }
        }
        return other.map(HookStatus.installedAtOtherPath) ?? .notInstalled
    }

    // MARK: Parsing and encoding

    private static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) }
    }

    private static func parseRoot(_ data: Data?) throws -> [String: JSONValue] {
        guard let data, !isBlank(data) else { return [:] }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw HookSettingsError.invalidJSON
        }
        guard case .object(let o) = value else {
            throw HookSettingsError.unexpectedShape("settings.json top level is not an object")
        }
        return o
    }

    private static func hooksObject(_ root: [String: JSONValue]) throws -> [String: JSONValue] {
        guard let hooks = root["hooks"] else { return [:] }
        guard case .object(let o) = hooks else {
            throw HookSettingsError.unexpectedShape("\"hooks\" is not an object")
        }
        return o
    }

    private static func permissionRequestEntries(_ hooks: [String: JSONValue]) throws -> [JSONValue] {
        guard let v = hooks["PermissionRequest"] else { return [] }
        guard case .array(let a) = v else {
            throw HookSettingsError.unexpectedShape("\"hooks.PermissionRequest\" is not an array")
        }
        return a
    }

    private static func encode(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    // MARK: Recognising our hook

    private static func isOurs(command: String) -> Bool {
        var s = command.trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = s.first, f == "\"" || f == "'" { s.removeFirst() }
        while let l = s.last, l == "\"" || l == "'" { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) == helperName
    }

    private static func isOurHook(_ hook: JSONValue) -> Bool {
        guard let command = hook["command"]?.stringValue else { return false }
        return isOurs(command: command)
    }

    private static func ourCommands(in entry: JSONValue) -> [String] {
        (entry["hooks"]?.arrayValue ?? []).compactMap { hook in
            guard let c = hook["command"]?.stringValue, isOurs(command: c) else { return nil }
            return c
        }
    }

    /// Removes our hook objects from an entry. `touched` says whether anything was removed;
    /// `remaining` is nil when the entry held nothing else and should be dropped.
    private static func strippingOurs(_ entry: JSONValue) -> (remaining: JSONValue?, touched: Bool) {
        guard case .object(var o) = entry, case .array(let hooks)? = o["hooks"] else { return (entry, false) }
        let rest = hooks.filter { !isOurHook($0) }
        if rest.count == hooks.count { return (entry, false) }
        if rest.isEmpty { return (nil, true) }
        o["hooks"] = .array(rest)
        return (.object(o), true)
    }
}
