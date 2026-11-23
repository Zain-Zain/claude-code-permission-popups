import AppKit
import ServiceManagement
import PermissionCore

/// Wires the socket server, the request queue, the cards, the hotkeys and the history.
/// Every decision, however it was made, goes through `decide(id:decision:)`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let trimEvery = 100

    let prefs = Preferences()
    let queue = RequestQueue()
    let history = HistoryStore(fileURL: AppPaths.historyURL)
    private(set) var panels: PanelController?
    private var statusMenu: StatusMenu?

    private var server: SocketServer?
    private var hotKeys: HotKeys?
    private var signalSources: [DispatchSourceSignal] = []
    private var appendsSinceTrim = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installTerminationSignals()

        // The 0700 directory must exist before binding: it covers the bind → chmod window.
        do {
            try AppPaths.ensureSupportDirectory()
        } catch {
            log("startup: cannot create the support directory (\(error)); quitting")
            NSApp.terminate(nil)
            return
        }

        // start() replaces whatever file is at the path, so make sure it is not a live server.
        if Self.isServerListening(at: AppPaths.socketPath) {
            log("startup: another instance is already running; quitting")
            NSApp.terminate(nil)
            return
        }

        trimHistory()
        panels = PanelController(queue: queue, prefs: prefs) { [weak self] id, decision in
            self?.decide(id: id, decision: decision)
        }

        statusMenu = StatusMenu(prefs: prefs, queue: queue, panels: panels, historyStore: history)

        let server = SocketServer(path: AppPaths.socketPath) { [weak self] wire, responder in
            self?.handle(wire, responder: responder)
        }
        do {
            try server.start()
        } catch {
            log("startup: cannot listen on the socket (\(error)); quitting")
            NSApp.terminate(nil)
            return
        }
        self.server = server
        log("startup: listening")

        let hotKeys = HotKeys(
            onAllow: { [weak self] in self?.decideOldest(.allow) },
            onDeny: { [weak self] in self?.decideOldest(.deny(message: denyMessage)) }
        )
        hotKeys.register()
        self.hotKeys = hotKeys

        registerLoginItemOnFirstLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Helpers get "pass" (print nothing), so Claude falls back to its own prompts.
        let open = queue.pending
        queue.passAll()
        for request in open {
            record(HistoryEntry(pending: request, outcome: .answeredElsewhere))
        }
        server?.stop()
        hotKeys?.unregister()
        log("quit: passed \(open.count) pending request(s)")
    }

    // MARK: - Decisions

    /// The single path for every decision: answer the helper, then record it.
    func decide(id: UUID, decision: Decision) {
        guard let request = queue.pending.first(where: { $0.id == id }),
              let outcome = queue.resolve(id: id, with: decision) else { return }
        log("decision: \(outcome.rawValue) \(id)")
        record(HistoryEntry(pending: request, outcome: outcome))
    }

    private func decideOldest(_ decision: Decision) {
        guard let oldest = queue.oldest else { return }
        decide(id: oldest.id, decision: decision)
    }

    // MARK: - Requests

    private func handle(_ wire: WireRequest, responder: SocketResponder) {
        guard let json = try? JSONEncoder().encode(wire.request),
              let request = try? PermissionRequest(json: json) else {
            log("request: unreadable, passing")
            responder.reply(WireReply(.pass))
            return
        }
        guard prefs.popupsEnabled else {
            responder.reply(WireReply(.pass))
            return
        }

        let pending = PendingRequest(request: request)
        queue.add(pending) { decision in
            responder.reply(WireReply(decision))
        }
        responder.onClose = { [weak self] in
            guard let self, self.queue.expire(id: pending.id) else { return }
            self.log("closed: \(pending.id) answered elsewhere")
            self.record(HistoryEntry(pending: pending, outcome: .answeredElsewhere))
        }
        log("request: \(pending.id) tool=\(request.toolName) pending=\(queue.pending.count)")
        if prefs.soundEnabled {
            NSSound(named: "Tink")?.play()
        }
    }

    // MARK: - History

    private func record(_ entry: HistoryEntry) {
        do {
            try history.append(entry)
        } catch {
            log("history: append failed (\(error))")
            return
        }
        appendsSinceTrim += 1
        if appendsSinceTrim >= Self.trimEvery {
            trimHistory()
        }
    }

    private func trimHistory() {
        appendsSinceTrim = 0
        do {
            try history.trim()
        } catch {
            log("history: trim failed (\(error))")
        }
    }

    // MARK: - Lifecycle helpers

    /// SIGTERM and SIGINT quit through NSApp.terminate, so applicationWillTerminate answers
    /// every waiting helper instead of the process just vanishing.
    private func installTerminationSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// On by default after the first launch. Only meaningful for the bundled app, so
    /// `swift run` skips it. A failure is logged and never stops the launch.
    private func registerLoginItemOnFirstLaunch() {
        guard !prefs.openAtLoginInitialized, Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            log("login item: registration failed (\(error))")
        }
        prefs.openAtLoginInitialized = true
    }

    /// A plain connect, sending nothing: true if a server accepts on `path`.
    private static func isServerListening(at path: String) -> Bool {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private func log(_ message: String) {
        NSLog("%@", message)
    }
}
