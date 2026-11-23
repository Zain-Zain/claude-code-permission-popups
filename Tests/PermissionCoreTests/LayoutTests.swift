import CoreGraphics
import Testing
@testable import PermissionCore

private let vf = CGRect(x: 0, y: 25, width: 1440, height: 875)

@Suite struct LayoutTests {
    @Test func bottomLeftFirstCard() {
        let frames = PanelLayout.frames(heights: [120], corner: .bottomLeft, visibleFrame: vf)
        #expect(frames[0] == CGRect(x: 16, y: 41, width: 360, height: 120))
    }

    @Test func bottomLeftStacksUp() {
        let frames = PanelLayout.frames(heights: [120, 80], corner: .bottomLeft, visibleFrame: vf)
        let expectedY: CGFloat = 41 + 120 + 8
        #expect(frames[1].minY == expectedY)
    }

    @Test func bottomRightX() {
        let frames = PanelLayout.frames(heights: [120], corner: .bottomRight, visibleFrame: vf)
        let expectedX: CGFloat = 1440 - 16 - 360
        #expect(frames[0].minX == expectedX)
    }

    @Test func topLeftFirstCard() {
        let frames = PanelLayout.frames(heights: [120], corner: .topLeft, visibleFrame: vf)
        let expectedMaxY: CGFloat = 25 + 875 - 16
        #expect(frames[0].maxY == expectedMaxY)
        #expect(frames[0].minX == 16)
    }

    @Test func topStacksDown() {
        let frames = PanelLayout.frames(heights: [120, 80], corner: .topRight, visibleFrame: vf)
        #expect(frames[1].maxY == frames[0].minY - 8)
    }

    @Test func pillBeyondLastCardBottom() {
        let last = CGRect(x: 16, y: 41, width: 360, height: 120)
        let pill = PanelLayout.overflowPillFrame(afterLast: last, corner: .bottomLeft)
        #expect(pill == CGRect(x: 16, y: 41 + 120 + 8, width: 360, height: 28))
    }

    @Test func pillBeyondLastCardTop() {
        let last = CGRect(x: 16, y: 700, width: 360, height: 120)
        let pill = PanelLayout.overflowPillFrame(afterLast: last, corner: .topRight)
        #expect(pill == CGRect(x: 16, y: 700 - 8 - 28, width: 360, height: 28))
    }

    @Test func offsetVisibleFrameShiftsFrames() {
        let second = CGRect(x: 1440, y: 25, width: 1440, height: 875)
        let frames = PanelLayout.frames(heights: [120], corner: .bottomLeft, visibleFrame: second)
        #expect(frames[0] == CGRect(x: 1440 + 16, y: 41, width: 360, height: 120))
    }

    @Test func extraHeightsAreIgnored() {
        let frames = PanelLayout.frames(heights: [10, 20, 30, 40, 50, 60], corner: .bottomLeft, visibleFrame: vf)
        #expect(frames.count == 4)
    }

    @Test func emptyHeightsGiveNoFrames() {
        #expect(PanelLayout.frames(heights: [], corner: .topLeft, visibleFrame: vf).isEmpty)
    }

    @Test func cornerTitles() {
        #expect(Corner.bottomLeft.title == "Bottom Left")
        #expect(Corner.bottomRight.title == "Bottom Right")
        #expect(Corner.topLeft.title == "Top Left")
        #expect(Corner.topRight.title == "Top Right")
    }
}
