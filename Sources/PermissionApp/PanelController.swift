import AppKit
import Combine
import SwiftUI
import PermissionCore

/// Keeps one `CardPanel` per visible pending request, plus the "+N more" pill, in step with
/// `RequestQueue.pending`. Panels exist only while their card is shown, and the elapsed-time
/// clock ticks only while at least one request is pending.
@MainActor
final class PanelController {
    private final class Card {
        let panel: CardPanel
        let state: CardState
        /// The frame this card is placed (or animating) at.
        var slot: CGRect
        /// When clicks and hotkeys may act on this card (see `ArmState`).
        var arming = ArmState()

        init(panel: CardPanel, state: CardState, slot: CGRect) {
            self.panel = panel
            self.state = state
            self.slot = slot
        }
    }

    private static let fadeDuration: TimeInterval = 0.15
    private static let slideDistance: CGFloat = 8
    /// With no screen to show a card on, a request without a card is passed after this long.
    private static let noScreenGrace: TimeInterval = 5

    private let queue: RequestQueue
    private let prefs: Preferences
    private let decide: (UUID, Decision) -> Void
    private let clock = CardClock()

    private var cards: [UUID: Card] = [:]
    private var heights: [UUID: CGFloat] = [:]
    private var pill: CardPanel?
    private var pillHost: NSHostingView<OverflowPillView>?
    /// Chosen when the stack goes from empty to non-empty, kept until it is empty again.
    private var screen: NSScreen?
    private var clockTick: AnyCancellable?
    private var subscriptions: Set<AnyCancellable> = []
    private var relayoutScheduled = false
    /// Requests with no card while there is no screen, and since when.
    private var cardlessSince: [UUID: Date] = [:]
    private var cardlessCheck: Task<Void, Never>?

    init(queue: RequestQueue, prefs: Preferences, decide: @escaping (UUID, Decision) -> Void) {
        self.queue = queue
        self.prefs = prefs
        self.decide = decide

        // @Published delivers the new value before the property changes: use the value given.
        queue.$pending
            .sink { [weak self] pending in self?.update(pending) }
            .store(in: &subscriptions)
        // Fires before the new value is stored, so lay out on the next turn.
        prefs.objectWillChange
            .sink { [weak self] _ in self?.scheduleRelayout() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.screensChanged() }
            .store(in: &subscriptions)
    }

    /// The global hotkeys may act on `id` only if it is the oldest card and has been shown,
    /// still, and the oldest for the arming delay. Otherwise the hotkey does nothing.
    func acceptsHotkey(for id: UUID) -> Bool {
        cards[id]?.arming.acceptsHotkey(at: Date()) ?? false
    }

    /// Briefly pulses the oldest card (the one the hotkeys act on) and brings it to front.
    func highlightOldest() {
        guard let oldest = queue.oldest, let card = cards[oldest.id] else { return }
        card.panel.orderFrontRegardless()
        card.state.flashing = true
        Task { @MainActor [weak state = card.state] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            state?.flashing = false
        }
    }

    // MARK: - Layout

    private func update(_ pending: [PendingRequest]) {
        let live = Set(pending.map(\.id))
        for id in Array(cards.keys) where !live.contains(id) {
            dismissCard(id)
        }
        heights = heights.filter { live.contains($0.key) }

        guard !pending.isEmpty else {
            stopCardlessTracking()
            screen = nil
            hidePill()
            stopClock()
            log("layout: pending=0 visible=0 overflow=0")
            return
        }

        if let current = screen, !NSScreen.screens.contains(current) { screen = nil }
        if screen == nil { screen = Self.screenWithMouse() }
        guard let screen else {
            trackCardless(pending)
            log("layout: no screen, pending=\(pending.count)")
            return
        }
        stopCardlessTracking()
        startClock()

        let visibleFrame = screen.visibleFrame
        let corner = prefs.corner
        let allHeights = pending.map(measuredHeight)
        let count = PanelLayout.visibleCount(heights: allHeights, visibleFrame: visibleFrame)
        let frames = PanelLayout.frames(heights: Array(allHeights.prefix(count)),
                                        corner: corner, visibleFrame: visibleFrame)

        for (index, request) in pending.prefix(frames.count).enumerated() {
            place(request, at: frames[index], isNext: index == 0, corner: corner)
        }
        // Visible before, but no longer fits (for example after a corner change): hide only.
        for request in pending.dropFirst(frames.count) where cards[request.id] != nil {
            dismissCard(request.id)
        }

        let overflow = pending.count - frames.count
        if overflow > 0, let last = frames.last {
            showPill(count: overflow, frame: PanelLayout.overflowPillFrame(afterLast: last, corner: corner))
        } else {
            hidePill()
        }
        log("layout: pending=\(pending.count) visible=\(frames.count) overflow=\(overflow)")
    }

    /// Lays the cards out again now (for example after the corner changed).
    func reflow() { relayout() }

    private func relayout() {
        update(queue.pending)
    }

    private func scheduleRelayout() {
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.relayoutScheduled = false
            self.relayout()
        }
    }

    private func screensChanged() {
        if let current = screen, !NSScreen.screens.contains(current) { screen = nil }
        relayout()
    }

    private static func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Card height at the fixed width, measured once per request.
    private func measuredHeight(_ request: PendingRequest) -> CGFloat {
        if let known = heights[request.id] { return known }
        let probe = NSHostingView(rootView: makeView(request, state: CardState()))
        let height = ceil(probe.fittingSize.height)
        heights[request.id] = height
        return height
    }

    // MARK: - No screen

    /// No screen to place cards on (displays asleep or being reconfigured): note when each
    /// request without a card started waiting, and check again once the grace period is up.
    /// Layout still retries on every screen change.
    private func trackCardless(_ pending: [PendingRequest]) {
        let now = Date()
        let live = Set(pending.map(\.id))
        cardlessSince = cardlessSince.filter { live.contains($0.key) && cards[$0.key] == nil }
        for request in pending where cards[request.id] == nil && cardlessSince[request.id] == nil {
            cardlessSince[request.id] = now
        }
        scheduleCardlessCheck()
    }

    private func stopCardlessTracking() {
        cardlessSince = [:]
        cardlessCheck?.cancel()
        cardlessCheck = nil
    }

    private func scheduleCardlessCheck() {
        guard cardlessCheck == nil, let earliest = cardlessSince.values.min() else { return }
        let wait = max(0, earliest.addingTimeInterval(Self.noScreenGrace).timeIntervalSinceNow) + 0.01
        cardlessCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.cardlessCheck = nil
            self.passCardless()
        }
    }

    /// Passes (Claude's own prompt takes over, recorded as answered elsewhere) every request
    /// that has had no card for the grace period, unless a screen has appeared meanwhile.
    private func passCardless() {
        relayout() // a screen may be back; this clears the tracking if so
        let now = Date()
        let due = cardlessSince
            .filter { cards[$0.key] == nil && now.timeIntervalSince($0.value) >= Self.noScreenGrace }
            .map(\.key)
        for id in due {
            cardlessSince[id] = nil
            log("card: no screen for \(Int(Self.noScreenGrace))s, passing \(id)")
            decide(id, .pass)
        }
        scheduleCardlessCheck()
    }

    // MARK: - Cards

    private func makeView(_ request: PendingRequest, state: CardState) -> CardView {
        let id = request.id
        let updates = request.alwaysAllowUpdates
        return CardView(
            pending: request,
            state: state,
            clock: clock,
            onDeny: { [weak self] in self?.decideFromCard(id, .deny(message: denyMessage)) },
            onAlwaysAllow: { [weak self] in self?.decideFromCard(id, .allowAlways(updatedPermissions: updates)) },
            onAllow: { [weak self] in self?.decideFromCard(id, .allow) }
        )
    }

    /// Buttons, Return and Escape on a card decide only once the card is armed, so a click
    /// meant for another card, or for the app under a card that just appeared, does nothing.
    private func decideFromCard(_ id: UUID, _ decision: Decision) {
        guard let card = cards[id] else { return }
        guard card.arming.acceptsClick(at: Date()) else {
            log("card: input ignored, not armed yet \(id)")
            return
        }
        decide(id, decision)
    }

    /// Restarts the card's arming after a show, move or new-oldest, dims its buttons until
    /// then, and re-checks when the delay is up.
    private func updateArming(_ card: Card, moved: Bool, isNext: Bool) {
        let now = Date()
        if moved { card.arming.moved(settlingAt: now.addingTimeInterval(Self.fadeDuration)) }
        card.arming.setOldest(isNext, at: now)
        refreshArmed(card)
        guard !card.state.armed, let armsAt = card.arming.armsAt else { return }
        let wait = max(0, armsAt.timeIntervalSince(now)) + 0.01
        Task { @MainActor [weak self, weak card] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, let card else { return }
            self.refreshArmed(card)
        }
    }

    private func refreshArmed(_ card: Card) {
        let armed = card.arming.acceptsClick(at: Date())
        if card.state.armed != armed { card.state.armed = armed }
    }

    private func place(_ request: PendingRequest, at frame: CGRect, isNext: Bool, corner: Corner) {
        if let card = cards[request.id] {
            if card.state.isNext != isNext { card.state.isNext = isNext }
            let moved = card.slot != frame
            if moved {
                card.slot = frame
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.fadeDuration
                    card.panel.animator().setFrame(frame, display: true)
                }
            }
            updateArming(card, moved: moved, isNext: isNext)
            return
        }

        let id = request.id
        let state = CardState()
        state.isNext = isNext
        let panel = CardPanel(contentRect: frame, keyable: true)
        panel.onAllow = { [weak self] in self?.decideFromCard(id, .allow) }
        panel.onDeny = { [weak self] in self?.decideFromCard(id, .deny(message: denyMessage)) }
        let host = CardHostingView(rootView: makeView(request, state: state))
        host.sizingOptions = []
        host.onHoverChange = { [weak state] hovering in state?.hovered = hovering }
        panel.contentView = host
        let card = Card(panel: panel, state: state, slot: frame)
        cards[id] = card
        updateArming(card, moved: true, isNext: isNext)

        // Fade and slide in from the corner's side. Never makeKey: the panel must not take focus.
        let isBottom = corner == .bottomLeft || corner == .bottomRight
        panel.setFrame(frame.offsetBy(dx: 0, dy: isBottom ? -Self.slideDistance : Self.slideDistance),
                       display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
        log("card: shown \(id) tool=\(request.request.toolName)")
    }

    private func dismissCard(_ id: UUID) {
        guard let card = cards.removeValue(forKey: id) else { return }
        let panel = card.panel
        panel.onAllow = nil
        panel.onDeny = nil
        panel.markDismissed()
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        }
        // Order out once the fade is done; the task keeps the panel alive until then.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.fadeDuration * 1_000_000_000))
            panel.orderOut(nil)
        }
        log("card: removed \(id)")
    }

    // MARK: - Pill

    private func showPill(count: Int, frame: CGRect) {
        if let pill, let pillHost {
            pillHost.rootView = OverflowPillView(count: count)
            if pill.frame != frame {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.fadeDuration
                    pill.animator().setFrame(frame, display: true)
                }
            }
            return
        }
        let panel = CardPanel(contentRect: frame, keyable: false)
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: OverflowPillView(count: count))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }
        pill = panel
        pillHost = host
    }

    private func hidePill() {
        guard let panel = pill else { return }
        pill = nil
        pillHost = nil
        panel.orderOut(nil)
    }

    // MARK: - Clock

    private func startClock() {
        guard clockTick == nil else { return }
        clock.now = Date()
        clockTick = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] now in self?.clock.now = now }
    }

    private func stopClock() {
        clockTick?.cancel()
        clockTick = nil
    }

    private func log(_ message: String) {
        NSLog("%@", message)
    }
}
