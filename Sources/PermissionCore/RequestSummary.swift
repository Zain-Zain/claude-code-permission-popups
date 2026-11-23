import Foundation

/// One rule Always Allow would save, as shown on the card.
public struct AlwaysAllowRule: Equatable, Sendable {
    /// For example "Bash(npm install:*) — this project".
    public let text: String
    /// Saved to `userSettings`, so it applies in every project.
    public let isUserWide: Bool
}

public struct RequestSummary: Equatable, Sendable {
    public let headline: String
    /// The command, path or input, cut at `maxPrimaryLength` characters (ending in "…" if cut).
    public let primary: String?
    /// How many characters of `primary` were cut off (0 if none).
    public let primaryHiddenCharacters: Int
    public let detail: String?
    public let cwd: String?
    public let rules: [AlwaysAllowRule]

    public var alwaysAllowRules: [String] { rules.map(\.text) }

    /// "(N more characters not shown)" when `primary` was cut, for display outside the
    /// scrolling text so a harmless head cannot hide a dangerous tail.
    public var truncationNote: String? {
        primaryHiddenCharacters > 0 ? "(\(primaryHiddenCharacters) more characters not shown)" : nil
    }

    public static let maxPrimaryLength = 2000
    static let maxEditSideLength = 200  // including the ellipsis
    static let planLineLimit = 6

    public init(_ r: PermissionRequest, homeDirectory: String = NSHomeDirectory()) {
        let input = r.toolInput
        func str(_ key: String) -> String? { input[key]?.stringValue }
        let cap: (String) -> String = { Self.capped($0) }

        var headline: String
        var primary: String?
        var detail: String?

        switch r.toolName {
        case "Bash":
            headline = "Claude wants to run a command"
            primary = str("command")
            detail = str("description").map(cap)
        case "Edit", "MultiEdit":
            headline = "Claude wants to edit a file"
            primary = str("file_path")
            let first = r.toolName == "MultiEdit" ? input["edits"]?.arrayValue?.first : input
            if let old = first?["old_string"]?.stringValue, let new = first?["new_string"]?.stringValue {
                detail = "− \(Self.clipped(old, limit: Self.maxEditSideLength - 1))\n+ \(Self.clipped(new, limit: Self.maxEditSideLength - 1))"
            }
        case "Write":
            headline = "Claude wants to create a file"
            primary = str("file_path")
        case "Read":
            headline = "Claude wants to read a file"
            primary = str("file_path")
        case "Grep", "Glob":
            headline = "Claude wants to search files"
            primary = str("pattern")
        case "WebFetch":
            headline = "Claude wants to fetch a web page"
            primary = str("url")
        case "WebSearch":
            headline = "Claude wants to search the web"
            primary = str("query")
        case "ExitPlanMode":
            headline = "Claude wants to approve its plan"
            primary = str("plan").map {
                $0.split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(Self.planLineLimit).joined(separator: "\n")
            }
        default:
            if r.toolName.hasPrefix("mcp__") {
                let parts = r.toolName.dropFirst(5).components(separatedBy: "__")
                let server = r.mcpServer ?? (parts.count > 1 ? parts[0] : nil)
                let tool = parts.count > 1 ? parts.dropFirst().joined(separator: "__") : parts[0]
                headline = server.map { "Claude wants to use \(tool) from \($0)" } ?? "Claude wants to use \(tool)"
            } else {
                headline = "Claude wants to use \(r.toolName)"
            }
            primary = input.compactString(maxLength: .max)
        }

        self.headline = headline
        let cut = primary.map { Self.cut($0, limit: Self.maxPrimaryLength) }
        self.primary = cut?.text
        self.primaryHiddenCharacters = cut?.hidden ?? 0
        self.detail = detail
        self.cwd = r.cwd.map { Self.abbreviate($0, home: homeDirectory) }
        self.rules = Self.displayRules(alwaysAllowUpdates(from: r.permissionSuggestions))
    }

    /// The rules to list on a card, in order: every user-wide ("all projects") rule, plus the
    /// others while the total stays within `limit`. `hidden` counts the others left out.
    public func displayedRules(limit: Int) -> (lines: [String], hidden: Int) {
        var budget = max(0, limit - rules.filter(\.isUserWide).count)
        var lines: [String] = []
        var hidden = 0
        for rule in rules {
            if rule.isUserWide {
                lines.append(rule.text)
            } else if budget > 0 {
                lines.append(rule.text)
                budget -= 1
            } else {
                hidden += 1
            }
        }
        return (lines, hidden)
    }

    /// Text over `limit` characters is cut and ends in "…"; `hidden` is the exact number of
    /// characters left out (0 if nothing was cut).
    static func cut(_ s: String, limit: Int) -> (text: String, hidden: Int) {
        let total = s.count
        guard total > limit else { return (s, 0) }
        return (String(s.prefix(limit)) + "…", total - limit)
    }

    static func capped(_ s: String, limit: Int = RequestSummary.maxPrimaryLength) -> String {
        cut(s, limit: limit).text
    }

    /// Short single-line cut for the edit preview, which is never the thing being approved alone.
    static func clipped(_ s: String, limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "…"
    }

    static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func destinationLabel(_ d: String?) -> String? {
        switch d {
        case "localSettings", "projectSettings": return "this project"
        case "userSettings": return "all projects"
        case "session": return "this session"
        default: return nil
        }
    }

    static func displayRules(_ updates: [JSONValue]) -> [AlwaysAllowRule] {
        updates.flatMap { u -> [AlwaysAllowRule] in
            let destination = u["destination"]?.stringValue
            let suffix = destinationLabel(destination).map { " — \($0)" } ?? ""
            return (u["rules"]?.arrayValue ?? []).compactMap { rule in
                guard let tool = rule["toolName"]?.stringValue else { return nil }
                let content = rule["ruleContent"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                return AlwaysAllowRule(text: (content.map { "\(tool)(\($0))" } ?? tool) + suffix,
                                       isUserWide: destination == "userSettings")
            }
        }
    }
}
