import Foundation
import Combine

public struct PendingRequest: Identifiable {
    public let id: UUID
    public let request: PermissionRequest
    public let summary: RequestSummary
    public let arrived: Date
    public let alwaysAllowUpdates: [JSONValue]

    public init(id: UUID, request: PermissionRequest, summary: RequestSummary,
                arrived: Date, alwaysAllowUpdates: [JSONValue]) {
        self.id = id
        self.request = request
        self.summary = summary
        self.arrived = arrived
        self.alwaysAllowUpdates = alwaysAllowUpdates
    }

    public init(request: PermissionRequest, arrived: Date = Date(), homeDirectory: String = NSHomeDirectory()) {
        self.init(id: UUID(), request: request,
                  summary: RequestSummary(request, homeDirectory: homeDirectory),
                  arrived: arrived,
                  alwaysAllowUpdates: PermissionCore.alwaysAllowUpdates(from: request.permissionSuggestions))
    }
}

/// Open permission requests, oldest first. Main-actor only. Each request's `respond`
/// closure is invoked at most once: the entry is removed before `respond` runs, so every
/// later `resolve`, `expire` or `passAll` for the same id finds nothing.
@MainActor
public final class RequestQueue: ObservableObject {
    @Published public private(set) var pending: [PendingRequest] = []
    private var responders: [UUID: (Decision) -> Void] = [:]

    public init() {}

    public var oldest: PendingRequest? { pending.first }

    /// A request whose id is already queued is ignored.
    public func add(_ p: PendingRequest, respond: @escaping (Decision) -> Void) {
        guard responders[p.id] == nil else { return }
        responders[p.id] = respond
        pending.append(p)
    }

    /// Responds with `d`, removes the request and returns the history outcome (`.pass` maps to
    /// `.answeredElsewhere`). Returns nil if the id is unknown or already handled.
    @discardableResult
    public func resolve(id: UUID, with d: Decision) -> HistoryEntry.Outcome? {
        guard let respond = remove(id) else { return nil }
        respond(d)
        switch d {
        case .allow: return .allowed
        case .allowAlways: return .alwaysAllowed
        case .deny: return .denied
        case .pass: return .answeredElsewhere
        }
    }

    /// Removes the request without responding (its connection went away). True if it was present.
    @discardableResult
    public func expire(id: UUID) -> Bool {
        remove(id) != nil
    }

    /// Responds `.pass` to every open request and empties the queue (used on quit).
    public func passAll() {
        let all = pending
        for p in all { resolve(id: p.id, with: .pass) }
    }

    private func remove(_ id: UUID) -> ((Decision) -> Void)? {
        guard let respond = responders.removeValue(forKey: id) else { return nil }
        pending.removeAll { $0.id == id }
        return respond
    }
}
