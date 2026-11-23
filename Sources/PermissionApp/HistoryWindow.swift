import AppKit
import SwiftUI
import PermissionCore

@MainActor
final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    private let store: HistoryStore

    init(store: HistoryStore) { self.store = store }

    func reload() { entries = store.load() }

    func clear() {
        do { try store.clear() } catch { NSLog("%@", "history: clear failed (\(error))") }
        reload()
    }
}

/// One resizable window listing past decisions, newest first. Closing it only hides it.
@MainActor
final class HistoryWindowController: NSObject {
    private let model: HistoryModel
    private var window: NSWindow?

    init(store: HistoryStore) {
        model = HistoryModel(store: store)
    }

    /// The one place the app takes focus, because the user explicitly asked for this window.
    func show() {
        model.reload()
        if window == nil {
            let view = HistoryView(model: model, onClear: { [weak self] in self?.confirmClear() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Permission History"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("HistoryWindow")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "This permanently deletes the recorded decisions on this Mac."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        // The user clicked Clear History: keep the confirmation in front.
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.model.clear() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            model.clear()
        }
    }
}

private struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.entries.isEmpty {
                Text("No history yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.entries) { HistoryRow(entry: $0) }
            }
            Divider()
            HStack {
                Text("\(model.entries.count) entries").foregroundStyle(.secondary)
                Spacer()
                Button("Clear History", action: onClear).disabled(model.entries.isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 480, minHeight: 300)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
                .help(label)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.headline).fontWeight(.medium)
                    Spacer()
                    Text(Self.relative.localizedString(for: entry.date, relativeTo: Date()))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                if let primary = entry.primary, !primary.isEmpty {
                    Text(primary.components(separatedBy: .newlines).first ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let cwd = entry.cwd, !cwd.isEmpty {
                    Text(cwd)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch entry.outcome {
        case .allowed: return "checkmark.circle.fill"
        case .alwaysAllowed: return "checkmark.seal.fill"
        case .denied: return "xmark.circle.fill"
        case .answeredElsewhere: return "arrow.uturn.right.circle"
        }
    }

    private var color: Color {
        switch entry.outcome {
        case .allowed, .alwaysAllowed: return .green
        case .denied: return .red
        case .answeredElsewhere: return .secondary
        }
    }

    private var label: String {
        switch entry.outcome {
        case .allowed: return "Allowed"
        case .alwaysAllowed: return "Always allowed"
        case .denied: return "Denied"
        case .answeredElsewhere: return "Answered elsewhere / expired"
        }
    }
}
