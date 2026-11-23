import AppKit

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    // NSApplication holds its delegate weakly; this scope never returns while the app runs.
    withExtendedLifetime(delegate) {
        app.run()
    }
}
