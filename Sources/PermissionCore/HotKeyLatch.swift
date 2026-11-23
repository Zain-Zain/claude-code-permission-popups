/// One decision per physical press of a global hotkey: after a press fires, further presses
/// of the same key (auto-repeat, or press events while it is held) are ignored until the
/// key is released. Holding ⌃⌥Return therefore approves at most one card.
public struct HotKeyLatch: Equatable, Sendable {
    private var held: Set<UInt32> = []

    public init() {}

    /// A press of hotkey `id`. True if it should fire (the key was not already held).
    public mutating func press(_ id: UInt32) -> Bool {
        held.insert(id).inserted
    }

    /// The hotkey `id` was released; its next press fires again.
    public mutating func release(_ id: UInt32) {
        held.remove(id)
    }
}
