import Foundation
import Testing
@testable import PermissionCore

@Suite struct ArmStateTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func neverPlacedIsDisarmed() {
        let a = ArmState()
        #expect(!a.acceptsClick(at: at(100)))
        #expect(!a.acceptsHotkey(at: at(100)))
        #expect(a.armsAt == nil)
    }

    /// Armed only once the card has stood still at its slot for the whole delay.
    @Test func armsAfterSettlingPlusDelay() {
        var a = ArmState()
        a.moved(settlingAt: at(0.15)) // shown at t0, animation ends at 0.15
        #expect(!a.acceptsClick(at: at(0.1)))
        #expect(!a.acceptsClick(at: at(0.6)))
        #expect(a.acceptsClick(at: at(0.65)))
        #expect(a.armsAt == at(0.65))
    }

    @Test func moveRestartsTimer() {
        var a = ArmState()
        a.moved(settlingAt: at(0))
        #expect(a.acceptsClick(at: at(1)))
        a.moved(settlingAt: at(1.15)) // reflow into a freed slot
        #expect(!a.acceptsClick(at: at(1.2)))
        #expect(!a.acceptsClick(at: at(1.6)))
        #expect(a.acceptsClick(at: at(1.65)))
    }

    /// A restart never makes the card armed sooner than an earlier, later-settling move.
    @Test func restartNeverShortensWait() {
        var a = ArmState()
        a.moved(settlingAt: at(2))
        a.moved(settlingAt: at(1))
        #expect(!a.acceptsClick(at: at(2.4)))
        #expect(a.acceptsClick(at: at(2.5)))
    }

    @Test func hotkeyNeedsOldest() {
        var a = ArmState()
        a.moved(settlingAt: at(0))
        #expect(a.acceptsClick(at: at(1)))
        #expect(!a.acceptsHotkey(at: at(1)))
    }

    /// Becoming the oldest restarts the timer: the hotkey target must have been the target for the delay.
    @Test func becomingOldestRestartsTimer() {
        var a = ArmState()
        a.moved(settlingAt: at(0))
        a.setOldest(true, at: at(5))
        #expect(!a.acceptsHotkey(at: at(5.1)))
        #expect(!a.acceptsClick(at: at(5.1)))
        #expect(a.acceptsHotkey(at: at(5.5)))
    }

    @Test func stayingOldestDoesNotRestart() {
        var a = ArmState()
        a.moved(settlingAt: at(0))
        a.setOldest(true, at: at(0))
        a.setOldest(true, at: at(3))
        #expect(a.acceptsHotkey(at: at(3)))
        a.setOldest(false, at: at(4))
        #expect(!a.acceptsHotkey(at: at(4)))
        #expect(a.acceptsClick(at: at(4)))
    }

    @Test func customDelay() {
        var a = ArmState(delay: 1)
        a.moved(settlingAt: at(0))
        #expect(!a.acceptsClick(at: at(0.9)))
        #expect(a.acceptsClick(at: at(1)))
    }
}
