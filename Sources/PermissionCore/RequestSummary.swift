import Foundation

public struct RequestSummary: Equatable, Sendable {
    public let headline: String
    public let primary: String?
    public let detail: String?
    public let cwd: String?
    public let alwaysAllowRules: [String]

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
            primary = str("command").map(cap)
            detail = str("description").map(cap)
        case "Edit", "MultiEdit":
            headline = "Claude wants to edit a file"
            primary = str("file_path").map(cap)
            let first = r.toolName == "MultiEdit" ? input["edits"]?.arrayValue?.first : input
            if let old = first?["old_string"]?.stringValue, let new = first?["new_string"]?.stringValue {
                detail = "− \(Self.capped(old, limit: Self.maxEditSideLength - 1))\n+ \(Self.capped(new, limit: Self.maxEditSideLength - 1))"
            }
        case "Write":
            headline = "Claude wants to create a file"
            primary = str("file_path").map(cap)
        case "Read":
            headline = "Claude wants to read a file"
            primary = str("file_path").map(cap)
        case "Grep", "Glob":
            headline = "Claude wants to search files"
            primary = str("pattern").map(cap)
        case "WebFetch":
            headline = "Claude wants to fetch a web page"
            primary = str("url").map(cap)
        case "WebSearch":
            headline = "Claude wants to search the web"
            primary = str("query").map(cap)
        case "ExitPlanMode":
            headline = "Claude wants to approve its plan"
            primary = str("plan").map {
                cap($0.split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(Self.planLineLimit).joined(separator: "\n"))
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
            primary = input.compactString(maxLength: Self.maxPrimaryLength)
        }

        self.headline = headline
        self.primary = primary
        self.detail = detail
        self.cwd = r.cwd.map { Self.abbreviate($0, home: homeDirectory) }
        self.alwaysAllowRules = Self.displayRules(alwaysAllowUpdates(from: r.permissionSuggestions))
    }

    static func capped(_ s: String, limit: Int = RequestSummary.maxPrimaryLength) -> String {
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

    static func displayRules(_ updates: [JSONValue]) -> [String] {
        updates.flatMap { u -> [String] in
            let suffix = destinationLabel(u["destination"]?.stringValue).map { " — \($0)" } ?? ""
            return (u["rules"]?.arrayValue ?? []).compactMap { rule in
                guard let tool = rule["toolName"]?.stringValue else { return nil }
                let content = rule["ruleContent"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                return (content.map { "\(tool)(\($0))" } ?? tool) + suffix
            }
        }
    }
}
