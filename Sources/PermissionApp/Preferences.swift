import Combine
import SwiftUI
import PermissionCore

/// User settings, stored in `UserDefaults`. Each change announces itself through
/// `objectWillChange`, so the card stack and (later) the menu can follow along.
@MainActor
final class Preferences: ObservableObject {
    /// Off: every request is answered `pass`, so Claude's own prompt handles it.
    @AppStorage("popupsEnabled") var popupsEnabled = true {
        willSet { objectWillChange.send() }
    }

    @AppStorage("soundEnabled") var soundEnabled = true {
        willSet { objectWillChange.send() }
    }

    @AppStorage("corner") var corner: Corner = .bottomLeft {
        willSet { objectWillChange.send() }
    }

    /// Set once the login item has been registered on first launch, so turning it off sticks.
    @AppStorage("openAtLoginInitialized") var openAtLoginInitialized = false {
        willSet { objectWillChange.send() }
    }
}
