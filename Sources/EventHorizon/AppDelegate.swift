import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: HorizonController?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, also when the binary runs outside the .app bundle.
        NSApp.setActivationPolicy(.accessory)

        menu.delegate = self
        let controller = HorizonController(menu: menu)
        self.controller = controller

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "smallcircle.filled.circle", accessibilityDescription: "Event Horizon")
        image?.isTemplate = true
        item.button?.image = image
        item.menu = menu
        statusItem = item

        controller.show()
    }

    /// Rebuilds the menu each time it opens, so the "Bring Back" item names the right file.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let controller else { return }

        let bringBack: NSMenuItem
        if let name = controller.lastItemName {
            bringBack = NSMenuItem(title: "Bring Back “\(name)”", action: #selector(bringBack(_:)), keyEquivalent: "")
            bringBack.target = self
        } else {
            bringBack = NSMenuItem(title: "Nothing to Bring Back", action: nil, keyEquivalent: "")
            bringBack.isEnabled = false
        }
        menu.addItem(bringBack)

        let count = controller.itemCount
        let summary = NSMenuItem(
            title: count == 0 ? "The hole is empty" : "\(count) item\(count == 1 ? "" : "s") · \(controller.massDescription)",
            action: nil,
            keyEquivalent: ""
        )
        summary.isEnabled = false
        menu.addItem(summary)

        menu.addItem(.separator())
        addItem("Open Trash", #selector(openTrash(_:)))
        addItem("Move Hole to Corner", #selector(moveToCorner(_:)))
        menu.addItem(.separator())
        addItem("Quit Event Horizon", #selector(quit(_:)), key: "q")
    }

    private func addItem(_ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func bringBack(_ sender: Any?) { controller?.bringBackLast() }
    @objc private func openTrash(_ sender: Any?) { controller?.openTrash() }
    @objc private func moveToCorner(_ sender: Any?) { controller?.moveToCorner() }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
}
