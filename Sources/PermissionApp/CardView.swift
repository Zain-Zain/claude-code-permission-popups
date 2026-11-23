import AppKit
import SwiftUI
import PermissionCore

/// Per-card display state owned by `PanelController`.
@MainActor
final class CardState: ObservableObject {
    /// This card is the oldest pending request, the one the global hotkeys act on.
    @Published var isNext = false
    @Published var hovered = false
    /// A short pulse from `PanelController.highlightOldest()`.
    @Published var flashing = false
}

/// One shared clock for every card's elapsed time. It only ticks while cards exist.
@MainActor
final class CardClock: ObservableObject {
    @Published var now = Date()
}

struct CardView: View {
    static let width = PanelLayout.width
    static let padding: CGFloat = 12
    static let cornerRadius: CGFloat = 14
    static let maxRulesShown = 3

    let pending: PendingRequest
    @ObservedObject var state: CardState
    let clock: CardClock
    let onDeny: () -> Void
    let onAlwaysAllow: () -> Void
    let onAllow: () -> Void

    private var summary: RequestSummary { pending.summary }
    private var canAlwaysAllow: Bool { !pending.alwaysAllowUpdates.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let primary = summary.primary, !primary.isEmpty {
                PrimaryTextBlock(text: primary,
                                 textWidth: Self.width - 2 * Self.padding - 2 * PrimaryTextBlock.inset)
            }
            if let detail = summary.detail, !detail.isEmpty {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let cwd = summary.cwd, !cwd.isEmpty {
                Text("in \(cwd)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if canAlwaysAllow {
                rules
            }
            buttons
        }
        .padding(Self.padding)
        .frame(width: Self.width, alignment: .leading)
        .background(VisualEffectBackground(cornerRadius: Self.cornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: state.flashing ? 2 : 1)
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .opacity(state.isNext ? 1 : 0)
                .help("Next: ⌃⌥↩ allows, ⌃⌥⎋ denies")
            Text(summary.headline)
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            ElapsedText(arrived: pending.arrived, clock: clock)
        }
    }

    private var rules: some View {
        let all = summary.alwaysAllowRules
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(all.prefix(Self.maxRulesShown).enumerated()), id: \.offset) { item in
                Text("Always allow: \(item.element)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if all.count > Self.maxRulesShown {
                Text("and \(all.count - Self.maxRulesShown) more rules")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var buttons: some View {
        // No SwiftUI keyboard shortcuts: Return and Escape are handled once, by CardPanel.
        // Always Allow deliberately has no shortcut at all.
        HStack(spacing: 8) {
            Button(action: onDeny) { Text("Deny ⎋") }
            Spacer(minLength: 0)
            if canAlwaysAllow {
                Button(action: onAlwaysAllow) { Text("Always Allow") }
            }
            Button(action: onAllow) { Text("Allow ↩") }
                .buttonStyle(AllowButtonStyle())
        }
        .padding(.top, 2)
    }

    private var borderColor: Color {
        if state.flashing { return .accentColor }
        return Color.primary.opacity(state.hovered ? 0.35 : 0.1)
    }
}

/// The default button, drawn in the accent colour even though the card's window is never
/// the active app's (`.borderedProminent` would draw grey there).
private struct AllowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.7 : 1))
            )
            .contentShape(Rectangle())
    }
}

/// Seconds since the request arrived. Isolated in its own view so the once-a-second tick
/// redraws only this label.
private struct ElapsedText: View {
    let arrived: Date
    @ObservedObject var clock: CardClock

    var body: some View {
        Text(Self.format(clock.now.timeIntervalSince(arrived)))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    static func format(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}

/// The command, path or input: monospaced, selectable, at most `maxLines` lines tall,
/// scrolling the rest. The height is measured with the same TextKit setup the text view
/// uses, so a short command gets a short block and a long one cannot grow the card.
struct PrimaryTextBlock: View {
    static let inset: CGFloat = 8
    static let maxLines = 6
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)

    let text: String
    let textWidth: CGFloat

    var body: some View {
        ScrollingText(text: text, width: textWidth)
            .frame(width: textWidth, height: Self.visibleHeight(text, width: textWidth))
            .padding(Self.inset)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
    }

    static func visibleHeight(_ text: String, width: CGFloat) -> CGFloat {
        min(contentHeight(text, width: width), lineHeight * CGFloat(maxLines))
    }

    static func contentHeight(_ text: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return max(lineHeight, ceil(layout.usedRect(for: container).height))
    }
}

private struct ScrollingText: NSViewRepresentable {
    let text: String
    let width: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: PrimaryTextBlock.lineHeight))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        // TextKit 1, matching PrimaryTextBlock.contentHeight.
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.font = PrimaryTextBlock.font
        textView.textColor = .labelColor
        textView.string = text
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }
}

/// The "+N more" pill shown when more requests are pending than fit.
struct OverflowPillView: View {
    let count: Int

    var body: some View {
        Text("+\(count) more")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: PanelLayout.width, height: PanelLayout.pillHeight)
            .background(VisualEffectBackground(cornerRadius: PanelLayout.pillHeight / 2))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }
}

/// A notification-style blurred background with rounded corners. Always drawn in its
/// active state, since the app itself is never active.
private struct VisualEffectBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.roundedMask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
