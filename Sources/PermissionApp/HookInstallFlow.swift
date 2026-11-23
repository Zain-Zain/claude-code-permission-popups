import AppKit
import PermissionCore

/// Installs or removes the PermissionRequest hook in Claude Code's settings.json.
/// Safety order, always: compute the new contents first (a `HookSettingsError` writes
/// nothing), then back the old file up, then write atomically with the old permissions.
@MainActor
final class HookInstallFlow {
    let settingsURL: URL
    let helperPath: String

    /// `~/.claude/settings.json`, following `HOME` (see `AppPaths.homeDirectory`).
    static var settingsURL: URL {
        AppPaths.homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// Inside the app bundle: `Contents/MacOS/permission-hook`. Under `swift run`: the
    /// sibling of the running executable.
    static var helperPath: String {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/permission-hook").path
        }
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.deletingLastPathComponent()
            .appendingPathComponent("permission-hook").path
    }

    init(settingsURL: URL? = nil, helperPath: String? = nil) {
        self.settingsURL = settingsURL ?? Self.settingsURL
        self.helperPath = helperPath ?? Self.helperPath
    }

    var status: HookStatus {
        HookSettings.status(of: try? SettingsFile(url: settingsURL).read(), helperPath: helperPath)
    }

    /// The exact entry that will be added, as pretty JSON.
    var entryJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(HookSettings.entry(helperPath: helperPath))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Asks for confirmation (unless told not to), then installs. Declining is not an error.
    func install(presentingConfirm: Bool = true) throws {
        try SettingsFile(url: settingsURL).update(
            confirm: presentingConfirm ? { [self] in confirmInstall() } : nil,
            compute: { try HookSettings.install(into: $0, helperPath: helperPath) })
    }

    func uninstall() throws {
        try SettingsFile(url: settingsURL).update { existing in
            guard let existing else { return nil }
            return try HookSettings.uninstall(from: existing, helperPath: helperPath)
        }
    }

    // MARK: - Confirmation

    private func confirmInstall() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install the Claude Code hook?"
        alert.informativeText = "This adds the entry below under hooks.PermissionRequest in:\n\(settingsURL.path)\n\nA backup of the existing file is saved next to it first. Everything else in the file is kept."
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 170))
        text.string = entryJSON
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        // The user chose Install from the menu: bring the confirmation to the front.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension HookSettingsError {
    /// Plain-language description for an alert.
    var explanation: String {
        switch self {
        case .invalidJSON:
            return "settings.json is not valid JSON (comments and trailing commas are not supported). Fix it by hand and try again."
        case .unexpectedShape(let detail):
            return "settings.json has an unexpected shape: \(detail)."
        }
    }
}
