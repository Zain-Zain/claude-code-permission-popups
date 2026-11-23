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

    /// Frames for the first `maxVisible` heights, oldest first. The oldest card
    /// sits nearest the corner; later cards stack away from it.
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
