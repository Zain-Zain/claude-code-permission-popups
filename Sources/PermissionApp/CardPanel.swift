import AppKit
import SwiftUI

/// A floating window that never takes focus on its own: it is shown with
/// `orderFrontRegardless()` only, and becomes key solely when the user clicks it
/// (a non-activating panel, so even then the frontmost app stays active).
final class CardPanel: NSPanel {
    /// Return or Enter while this card is key.
    var onAllow: (() -> Void)?
    /// Escape while this card is key.
    var onDeny: (() -> Void)?

    private let keyable: Bool

    /// `keyable: false` is for the "+N more" pill, which never takes keyboard input.
    init(contentRect: NSRect, keyable: Bool) {
        self.keyable = keyable
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        // isFloatingPanel resets the level to .floating, so set the level after it.
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
    }

    /// True so a click can make the card key without activating the app.
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    /// Return/Enter and Escape are taken here, before any view (such as the selectable
    /// command text) can consume them, so each press triggers exactly one decision.
    /// Key events only reach a window that is key, so this acts on the clicked card alone.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleDecisionKey(event) { return }
        super.sendEvent(event)
    }

    private func handleDecisionKey(_ event: NSEvent) -> Bool {
        let blocking: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(blocking).isEmpty else { return false }
        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            if !event.isARepeat { onAllow?() }
            return true
        case 53: // Escape
            if !event.isARepeat { onDeny?() }
            return true
        default:
            return false
        }
    }
}

/// Hosts a card's SwiftUI content.
/// - Accepts the first mouse, so one click on Allow/Deny works on a card that is not key.
/// - Asks the panel to become key on click (the panel has `becomesKeyOnlyIfNeeded`, which
///   otherwise only lets text fields make it key), so Return/Escape then apply to it.
/// - Reports hover with an always-active tracking area (the app is never active), which
///   drives a visual highlight only. Hover never makes the card key.
final class CardHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea { onHoverChange?(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea { onHoverChange?(false) }
    }
}
