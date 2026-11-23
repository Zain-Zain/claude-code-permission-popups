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

    /// POSIX single-quoted form of `path`; each embedded `'` becomes `'\''`.
    public static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Exact inverse of `shellQuoted`. Returns nil when `command` is not in that format.
    private static func unquoteShellQuoted(_ command: String) -> String? {
        let chars = Array(command)
        var i = 0
        var out = ""
        while true {
            guard i < chars.count, chars[i] == "'" else { return nil }
            i += 1
            while i < chars.count, chars[i] != "'" { out.append(chars[i]); i += 1 }
            guard i < chars.count else { return nil }  // unterminated
            i += 1  // closing quote
            if i == chars.count { return out }
            // Only the `\'` escape followed by a reopening quote continues the string.
            guard i + 1 < chars.count,
                  chars[i] == "\\", chars[i + 1] == "'" else { return nil }
            out.append("'")
            i += 2
        }
    }

    /// The command with our own quoting removed. Falls back to trimming and stripping stray
    /// quote characters for hand-written or legacy commands.
    private static func unquoted(_ command: String) -> String {
        let t = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = unquoteShellQuoted(t) { return exact }
        var s = t
        while let f = s.first, f == "\"" || f == "'" { s.removeFirst() }
        while let l = s.last, l == "\"" || l == "'" { s.removeLast() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func entry(helperPath: String) -> JSONValue {
        .object([
            "matcher": .string("*"),
            "hooks": .array([.object([
                "type": .string("command"),
                "command": .string(shellQuoted(helperPath)),
                "timeout": .number(Double(timeout)),
            ])]),
        ])
    }

    public static func install(into existing: Data?, helperPath: String) throws -> Data {
        var root = try parseRoot(existing, requireExactNumbers: true)
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
        var root = try parseRoot(existing, requireExactNumbers: true)
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

    private static func parseRoot(_ data: Data?, requireExactNumbers: Bool = false) throws -> [String: JSONValue] {
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
        if requireExactNumbers { try checkNumbersRoundTrip(data) }
        return o
    }

    /// JSONValue stores numbers as Double, so a literal like 9007199254740993 would be silently
    /// rewritten. We tokenize every number literal in the raw text (skipping string contents and
    /// escapes) and refuse the edit if any literal is not exactly preserved by its Double: literals
    /// with <= 15 significant digits always round-trip; longer ones must equal the Double's shortest
    /// decimal representation numerically.
    private static func checkNumbersRoundTrip(_ data: Data) throws {
        let bytes = [UInt8](data)
        var i = 0
        var inString = false
        while i < bytes.count {
            let b = bytes[i]
            if inString {
                if b == UInt8(ascii: "\\") { i += 1 } else if b == UInt8(ascii: "\"") { inString = false }
                i += 1
                continue
            }
            if b == UInt8(ascii: "\"") { inString = true; i += 1; continue }
            let isDigit = b >= 0x30 && b <= 0x39
            guard isDigit || b == UInt8(ascii: "-") else { i += 1; continue }
            var j = i + 1
            while j < bytes.count, "0123456789+-.eE".utf8.contains(bytes[j]) { j += 1 }
            let text = String(decoding: bytes[i..<j], as: UTF8.self)
            if !numberLiteralIsExact(text) {
                throw HookSettingsError.unexpectedShape("number cannot be preserved exactly")
            }
            i = j
        }
    }

    private static func numberLiteralIsExact(_ text: String) -> Bool {
        guard let d = Double(text), d.isFinite else { return false }
        let mantissa = text.prefix { $0 != "e" && $0 != "E" }
        let digits = mantissa.filter(\.isNumber).drop { $0 == "0" }
        if digits.count <= 15 { return true }
        guard let exact = Decimal(string: text), let back = Decimal(string: "\(d)") else { return false }
        return exact == back
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
        unquoted(command).split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) == helperName
    }

    private static func isOurHook(_ hook: JSONValue) -> Bool {
        guard let command = hook["command"]?.stringValue else { return false }
        return isOurs(command: command)
    }

    private static func ourCommands(in entry: JSONValue) -> [String] {
        (entry["hooks"]?.arrayValue ?? []).compactMap { hook in
            guard let c = hook["command"]?.stringValue, isOurs(command: c) else { return nil }
            return unquoted(c)
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
