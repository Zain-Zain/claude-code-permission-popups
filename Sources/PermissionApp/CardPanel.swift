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
        // Cards keep taking clicks while one of the app's own alerts is up (menu actions).
        worksWhenModal = true
    }

    /// Whether a click may reach the card right now (`ArmState`). While false, the whole
    /// click (down, drags, up) is swallowed: no button acts and the card does not become key.
    var acceptsClick: () -> Bool = { false }

    /// Set by a mouse-down on this card, cleared when it stops being key or is dismissed,
    /// or when the mouse-down did not make it key.
    private var clickArmed = false
    /// Swallowing the rest of a click that started while the card was disarmed.
    private var swallowingClick = false
    private var dismissed = false

    /// Only a mouse-down on this card can make it key. When another window closes or
    /// orders out, AppKit looks for a new key window; every card refuses, so a card the
    /// user never clicked can never receive their keystrokes.
    override var canBecomeKey: Bool { keyable && clickArmed && !dismissed }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        clickArmed = false
    }

    /// Called when the card starts fading out: it stops taking keystrokes at once and can
    /// never become key again. A key card leaves the screen now (skipping the fade), which
    /// is the supported way to give up key status.
    func markDismissed() {
        dismissed = true
        clickArmed = false
        if isKeyWindow { orderOut(nil) }
    }

    /// Return/Enter and Escape are taken here, before any view (such as the selectable
    /// command text) can consume them, so each press triggers exactly one decision.
    /// Key events only reach a window that is key, so this acts on the clicked card alone.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard acceptsClick() else {
                swallowingClick = true
                return
            }
            swallowingClick = false
            clickArmed = true // before super makes it key
            super.sendEvent(event)
            // Mouse tracking is over when super returns; a click that did not make the card
            // key (a subview that does not need it) must not leave it able to become key later.
            if !isKeyWindow { clickArmed = false }
            return
        case .leftMouseDragged where swallowingClick:
            return
        case .leftMouseUp where swallowingClick:
            swallowingClick = false
            return
        case .keyDown:
            if handleDecisionKey(event) { return }
        default:
            break
        }
        super.sendEvent(event)
    }

    private func handleDecisionKey(_ event: NSEvent) -> Bool {
        let blocking: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(blocking).isEmpty else { return false }
        switch event.keyCode {
        case 48, 49: // Tab and Space: Full Keyboard Access must not be able to press Always Allow
            return true
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
