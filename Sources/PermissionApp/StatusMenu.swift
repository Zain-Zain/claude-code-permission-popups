import AppKit
import Combine
import ServiceManagement
import PermissionCore

/// The menu bar item: pending count, settings toggles, history and the hook row.
/// The menu is rebuilt-in-place state: item states are refreshed in `menuWillOpen`.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let prefs: Preferences
    private let queue: RequestQueue
    private let panels: PanelController?
    private let history: HistoryWindowController
    private let hook = HookInstallFlow()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let pendingItem = NSMenuItem()
    private let popupsItem = NSMenuItem(title: "Popups", action: #selector(togglePopups), keyEquivalent: "")
    private let soundItem = NSMenuItem(title: "Sound", action: #selector(toggleSound), keyEquivalent: "")
    private let positionItem = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let hookItem = NSMenuItem()
    private var cornerItems: [Corner: NSMenuItem] = [:]
    private var subscription: AnyCancellable?

    private var isBundledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    init(prefs: Preferences, queue: RequestQueue, panels: PanelController?, historyStore: HistoryStore) {
        self.prefs = prefs
        self.queue = queue
        self.panels = panels
        self.history = HistoryWindowController(store: historyStore)
        super.init()
        buildMenu()
        statusItem.menu = menu
        // @Published delivers the new value before it is stored: use the value given.
        subscription = queue.$pending.sink { [weak self] pending in
            self?.pendingChanged(count: pending.count)
        }
    }

    // MARK: - Building

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        for item in [popupsItem, soundItem, loginItem] { item.target = self }

        let positionMenu = NSMenu()
        for corner in Corner.allCases {
            let item = NSMenuItem(title: corner.title, action: #selector(selectCorner(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = corner.rawValue
            positionMenu.addItem(item)
            cornerItems[corner] = item
        }
        positionItem.submenu = positionMenu

        pendingItem.isEnabled = false
        hookItem.target = self

        menu.addItem(pendingItem)
        menu.addItem(.separator())
        menu.addItem(popupsItem)
        menu.addItem(soundItem)
        menu.addItem(positionItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let historyItem = NSMenuItem(title: "History…", action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        menu.addItem(hookItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        refreshState()
        pendingChanged(count: queue.pending.count)
    }

    // MARK: - State

    func menuWillOpen(_ menu: NSMenu) {
        refreshState()
    }

    private func pendingChanged(count: Int) {
        pendingItem.title = count == 0 ? "No pending requests"
            : count == 1 ? "● 1 pending request" : "● \(count) pending requests"
        guard let button = statusItem.button else { return }
        let name = count == 0 ? "checkmark.shield" : "checkmark.shield.fill"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Permission Popups")
        button.title = count == 0 ? "" : " \(count)"
        button.imagePosition = count == 0 ? .imageOnly : .imageLeading
    }

    private func refreshState() {
        popupsItem.state = prefs.popupsEnabled ? .on : .off
        soundItem.state = prefs.soundEnabled ? .on : .off
        for (corner, item) in cornerItems { item.state = corner == prefs.corner ? .on : .off }

        if isBundledApp {
            loginItem.title = "Open at Login"
            loginItem.isEnabled = true
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginItem.title = "Open at Login (needs the app bundle)"
            loginItem.isEnabled = false
            loginItem.state = .off
        }

        hookItem.submenu = nil
        hookItem.state = .off
        switch hook.status {
        case .notInstalled:
            hookItem.title = "Install Claude Code Hook…"
            hookItem.action = #selector(installHook)
            hookItem.isEnabled = true
        case .installed:
            hookItem.title = "Hook: Installed ✓"
            hookItem.action = nil
            let sub = NSMenu()
            let uninstall = NSMenuItem(title: "Uninstall Claude Code Hook", action: #selector(uninstallHook), keyEquivalent: "")
            uninstall.target = self
            sub.addItem(uninstall)
            hookItem.submenu = sub
            hookItem.isEnabled = true
        case .installedAtOtherPath:
            hookItem.title = "Hook points to an old location — Reinstall…"
            hookItem.action = #selector(installHook)
            hookItem.isEnabled = true
        }
    }

    // MARK: - Actions

    @objc private func togglePopups() { prefs.popupsEnabled.toggle() }
    @objc private func toggleSound() { prefs.soundEnabled.toggle() }

    @objc private func selectCorner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let corner = Corner(rawValue: raw) else { return }
        prefs.corner = corner
        panels?.reflow()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert("Could not change “Open at Login”", error.localizedDescription)
        }
    }

    @objc private func showHistory() { history.show() }

    @objc private func installHook() {
        do {
            try hook.install()
        } catch let error as HookSettingsError {
            showAlert("The hook was not installed", error.explanation + "\n\nNothing was changed.")
        } catch {
            showAlert("The hook was not installed", error.localizedDescription)
        }
    }

    @objc private func uninstallHook() {
        do {
            try hook.uninstall()
        } catch let error as HookSettingsError {
            showAlert("The hook was not removed", error.explanation + "\n\nNothing was changed.")
        } catch {
            showAlert("The hook was not removed", error.localizedDescription)
        }
    }

    private func showAlert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        // Menu actions only: bring the alert to the front so it cannot hide behind other apps.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
