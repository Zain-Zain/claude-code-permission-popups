import Foundation

public struct PermissionRequest: Equatable, Sendable {
    public let sessionId: String
    public let cwd: String?
    public let permissionMode: String?
    public let toolName: String
    public let toolInput: JSONValue
    public let mcpServer: String?
    public let permissionSuggestions: [JSONValue]
    public let raw: JSONValue

    public enum ParseError: Error, Equatable {
        case notAnObject
        case wrongEvent
        case missingToolName
    }

    public init(json: Data) throws {
        let raw = try JSONDecoder().decode(JSONValue.self, from: json)
        guard raw.objectValue != nil else { throw ParseError.notAnObject }
        guard raw["hook_event_name"]?.stringValue == "PermissionRequest" else { throw ParseError.wrongEvent }
        guard let tool = raw["tool_name"]?.stringValue else { throw ParseError.missingToolName }
        self.raw = raw
        self.toolName = tool
        self.sessionId = raw["session_id"]?.stringValue ?? ""
        self.cwd = raw["cwd"]?.stringValue
        self.permissionMode = raw["permission_mode"]?.stringValue
        if let input = raw["tool_input"], input.objectValue != nil {
            self.toolInput = input
        } else {
            self.toolInput = .object([:])
        }
        self.mcpServer = raw["mcp_server"]?.stringValue
        self.permissionSuggestions = raw["permission_suggestions"]?.arrayValue ?? []
    }
}
