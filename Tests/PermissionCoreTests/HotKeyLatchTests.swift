import Testing
@testable import PermissionCore

@Suite struct HotKeyLatchTests {
    /// Presses each id in turn and returns which presses fired.
    private func fired(_ latch: inout HotKeyLatch, _ presses: [UInt32]) -> [Bool] {
        presses.map { latch.press($0) }
    }

    @Test func firesOncePerPressUntilReleased() {
        var latch = HotKeyLatch()
        // Held down: auto-repeat or further press events do nothing.
        #expect(fired(&latch, [1, 1, 1]) == [true, false, false])
        latch.release(1)
        #expect(fired(&latch, [1]) == [true])
    }

    @Test func keysAreIndependent() {
        var latch = HotKeyLatch()
        #expect(fired(&latch, [1, 2]) == [true, true])
        latch.release(2)
        #expect(fired(&latch, [1, 2]) == [false, true])
    }

    @Test func releaseWithoutPressIsHarmless() {
        var latch = HotKeyLatch()
        latch.release(7)
        #expect(fired(&latch, [7]) == [true])
    }
}
