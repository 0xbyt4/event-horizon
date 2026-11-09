import AppKit

/// A borderless, transparent panel that sits on the desktop, above the desktop icons
/// and below all app windows. It shows on every desktop Space and never takes focus.
final class FloatingPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    /// The effects panel is larger than the hole. Near the top of the screen, AppKit
    /// moves such a panel down below the menu bar, so the drawn hole and the drop
    /// target no longer share a center. Keep the frame exactly as given.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
