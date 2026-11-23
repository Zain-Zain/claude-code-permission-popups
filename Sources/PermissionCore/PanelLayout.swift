import CoreGraphics

public enum Corner: String, CaseIterable, Codable {
    case bottomLeft, bottomRight, topLeft, topRight

    public var title: String {
        switch self {
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        }
    }
}

/// Pure AppKit-coordinate layout (origin bottom-left, y grows upward).
public enum PanelLayout {
    public static let width: CGFloat = 360
    public static let margin: CGFloat = 16
    public static let gap: CGFloat = 8
    public static let pillHeight: CGFloat = 28
    public static let maxVisible = 4

    /// How many of the leading heights (capped at `maxVisible`) fit vertically inside
    /// `visibleFrame`, leaving room for the overflow pill when some heights are not shown.
    /// Returns 0 for empty input, otherwise at least 1, so the oldest card is always shown.
    public static func visibleCount(heights: [CGFloat], visibleFrame: CGRect) -> Int {
        guard !heights.isEmpty else { return 0 }
        let available = visibleFrame.height - 2 * margin
        var best = 1
        var used: CGFloat = 0
        for k in 1...min(maxVisible, heights.count) {
            used += heights[k - 1] + (k > 1 ? gap : 0)
            let pillSpace = k < heights.count ? gap + pillHeight : 0
            if used + pillSpace <= available {
                best = k
            }
        }
        return best
    }

    /// Lays out exactly the heights given, oldest first, up to `maxVisible`. The oldest
    /// card sits nearest the corner; later cards stack away from it. This does not clamp
    /// to the screen: callers pass `heights.prefix(visibleCount(...))` to keep the stack
    /// inside `visibleFrame`.
    public static func frames(heights: [CGFloat], corner: Corner, visibleFrame: CGRect) -> [CGRect] {
        let isLeft = corner == .bottomLeft || corner == .topLeft
        let isBottom = corner == .bottomLeft || corner == .bottomRight
        let x = isLeft ? visibleFrame.minX + margin : visibleFrame.maxX - margin - width
        var cursor = isBottom ? visibleFrame.minY + margin : visibleFrame.maxY - margin

        var result: [CGRect] = []
        for height in heights.prefix(maxVisible) {
            let y = isBottom ? cursor : cursor - height
            result.append(CGRect(x: x, y: y, width: width, height: height))
            cursor = isBottom ? cursor + height + gap : cursor - height - gap
        }
        return result
    }

    /// The "+N more" pill, placed `gap` beyond the last card in the stacking direction.
    public static func overflowPillFrame(afterLast: CGRect, corner: Corner) -> CGRect {
        let isLeft = corner == .bottomLeft || corner == .topLeft
        let isBottom = corner == .bottomLeft || corner == .bottomRight
        let x = isLeft ? afterLast.minX : afterLast.maxX - width
        let y = isBottom ? afterLast.maxY + gap : afterLast.minY - gap - pillHeight
        return CGRect(x: x, y: y, width: width, height: pillHeight)
    }
}
