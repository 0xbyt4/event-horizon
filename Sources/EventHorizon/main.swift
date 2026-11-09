import AppKit

// Plain AppKit entry point. The app has no regular windows,
// only the black hole and a menu bar item.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
