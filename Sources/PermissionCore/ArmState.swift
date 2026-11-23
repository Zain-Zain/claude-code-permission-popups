import Foundation

/// When a card may act on a click or a hotkey. A card that just appeared, moved into a
/// freed slot, or just became the oldest could be under the pointer or the hotkey before
/// the user has seen it, so it ignores input until it has stood still for `delay`.
///
/// One timer covers both rules: every move restarts it from the moment the card settles
/// (after its animation), and becoming the oldest restarts it too. So "armed and oldest"
/// means the card has been at its slot, and the hotkey target, for at least `delay`.
/// Pure value type: the caller passes the current time.
public struct ArmState: Equatable, Sendable {
    public static let defaultDelay: TimeInterval = 0.5

    public let delay: TimeInterval
    /// When the card stops (or stopped) moving at its current slot. Nil until placed.
    public private(set) var settledAt: Date?
    public private(set) var isOldest = false

    public init(delay: TimeInterval = ArmState.defaultDelay) {
        self.delay = delay
    }

    /// The card was shown, moved or reflowed, and will stand still from `settlingAt`.
    public mutating func moved(settlingAt: Date) {
        restart(from: settlingAt)
    }

    /// Records whether the card is the oldest (the hotkey target). Becoming the oldest
    /// restarts the timer at `now`; staying or stopping being the oldest does not.
    public mutating func setOldest(_ oldest: Bool, at now: Date) {
        if oldest && !isOldest { restart(from: now) }
        isOldest = oldest
    }

    /// When the card becomes armed, if it has been placed.
    public var armsAt: Date? { settledAt?.addingTimeInterval(delay) }

    /// A click on the card's buttons (or Return/Escape on it) may decide.
    public func acceptsClick(at now: Date) -> Bool {
        guard let armsAt else { return false }
        return now >= armsAt
    }

    /// The global hotkeys may decide this card.
    public func acceptsHotkey(at now: Date) -> Bool {
        isOldest && acceptsClick(at: now)
    }

    /// Never moves the arming time earlier.
    private mutating func restart(from date: Date) {
        settledAt = max(settledAt ?? date, date)
    }
}
