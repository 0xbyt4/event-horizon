import AppKit
import HorizonCore

/// Owns the two windows of the black hole and connects them to the Trash.
///
/// - The effects window is large and ignores the mouse. It only draws the hole and the animations.
/// - The target window is the small circle over the hole. It accepts drops, moves the hole
///   and brings back the last item on double-click.
@MainActor
final class HorizonController {
    let menu: NSMenu
    private(set) var center: CGPoint

    private let trash = TrashService()
    private let effectsPanel = FloatingPanel()
    private let targetPanel = FloatingPanel()
    private let holeView: HoleView
    private let targetView = DropTargetView(frame: .zero)
    private var radius = Physics.baseRadius
    private var mouseMonitor: Any?
    private var dragChangeCount = 0
    private var dragHasFiles: Bool?
    private var dragIsNear = false
    private var sweeping = false
    private var sweepItems: [DesktopItem] = []
    private var shownAutomationHelp = false

    private static let centerKey = "holeCenter"
    /// Room for the hole and an ejected icon (48 pt) at the end of its flight.
    /// The window backing store grows with the square of this side, so it follows the hole size.
    private static func effectsSide(_ radius: CGFloat) -> CGFloat {
        ((Physics.ejectDistance(radius) + 28) * 2).rounded(.up)
    }

    init(menu: NSMenu) {
        self.menu = menu
        let side = Self.effectsSide(Physics.baseRadius)
        holeView = HoleView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        center = Self.savedCenter() ?? Self.cornerCenter()

        effectsPanel.contentView = holeView
        effectsPanel.ignoresMouseEvents = true
        targetPanel.contentView = targetView
        targetView.controller = self

        center = clamped(center)
        layout()
        watchFileDrags()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    func show() {
        targetPanel.orderFrontRegardless()
        effectsPanel.orderFrontRegardless()
    }

    // MARK: - Menu data

    var lastItemName: String? { trash.items.last?.name }
    var itemCount: Int { trash.items.count }
    var massDescription: String {
        ByteCountFormatter.string(fromByteCount: trash.totalSize, countStyle: .file)
    }

    // MARK: - Position

    func moveHole(to point: CGPoint) {
        center = clamped(point)
        layout()
        sweepNearby()
    }

    func moveToCorner() {
        center = clamped(Self.cornerCenter())
        layout()
        saveCenter()
    }

    func saveCenter() {
        UserDefaults.standard.set([Double(center.x), Double(center.y)], forKey: Self.centerKey)
    }

    private func screensChanged() {
        center = clamped(center)
        layout()
    }

    private func layout() {
        let side = Self.effectsSide(radius)
        effectsPanel.setFrame(CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side), display: false)
        let capture = Physics.captureRadius(radius)
        targetPanel.setFrame(CGRect(x: center.x - capture, y: center.y - capture, width: capture * 2, height: capture * 2), display: true)
    }

    /// Keeps the hole inside the visible area of the screen it is on.
    private func clamped(_ point: CGPoint) -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return point }
        let frame = screen.visibleFrame
        let margin = radius * 1.5
        return CGPoint(
            x: min(frame.maxX - margin, max(frame.minX + margin, point.x)),
            y: min(frame.maxY - margin, max(frame.minY + margin, point.y))
        )
    }

    private static func cornerCenter() -> CGPoint {
        guard let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return CGPoint(x: 200, y: 200) }
        return CGPoint(x: frame.maxX - 90, y: frame.minY + 90)
    }

    private static func savedCenter() -> CGPoint? {
        guard let values = UserDefaults.standard.array(forKey: centerKey) as? [Double], values.count == 2 else { return nil }
        let point = CGPoint(x: values[0], y: values[1])
        return NSScreen.screens.contains(where: { $0.frame.contains(point) }) ? point : nil
    }

    // MARK: - Sweeping desktop icons while the user moves the hole

    /// Starts a sweep: asks Finder once where the desktop icons are.
    func holeDragBegan() {
        sweeping = true
        sweepItems = []
        guard DesktopItems.areVisible else { return }
        Task { [weak self] in
            let result = await DesktopItems.fetch()
            guard let self, self.sweeping else { return }
            switch result {
            case .success(let items):
                self.sweepItems = items.filter { item in
                    !self.trash.items.contains { $0.originalURL.standardizedFileURL == item.url.standardizedFileURL }
                }
                self.sweepNearby()
            case .failure(.notAuthorized):
                self.showAutomationHelp()
            case .failure(.failed):
                break
            }
        }
    }

    func holeDragEnded() {
        sweeping = false
        sweepItems = []
    }

    /// Swallows the desktop icons inside the capture radius. Holding Option moves the hole without sweeping.
    private func sweepNearby() {
        guard sweeping, !sweepItems.isEmpty, !NSEvent.modifierFlags.contains(.option) else { return }
        let caught = DesktopSweep.captured(sweepItems, center: center, radius: radius)
        guard !caught.isEmpty else { return }
        sweepItems.removeAll { caught.contains($0) }
        _ = swallow(caught.map { (url: $0.url, point: $0.center) })
    }

    private func showAutomationHelp() {
        guard !shownAutomationHelp else { return }
        shownAutomationHelp = true
        let alert = NSAlert()
        alert.messageText = "Event Horizon cannot see the desktop icons"
        alert.informativeText = "To swallow icons as the hole moves, allow Event Horizon to control Finder in System Settings > Privacy & Security > Automation."
        NSApp.activate()
        alert.runModal()
    }

    // MARK: - Pull while the user drags files

    /// Watches mouse drags in other apps. When the drag pasteboard holds file URLs,
    /// the hole reacts as the files come near. Mouse events need no special permission.
    private func watchFileDrags() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleGlobalMouse(event) }
        }
    }

    private func handleGlobalMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            dragHasFiles = nil
        case .leftMouseDragged:
            if dragHasFiles == nil {
                let pasteboard = NSPasteboard(name: .drag)
                // The pasteboard changes when a new drag session starts.
                guard pasteboard.changeCount != dragChangeCount else { return }
                dragHasFiles = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            }
            if dragHasFiles == true { fileDragMoved(to: NSEvent.mouseLocation) }
        case .leftMouseUp:
            if dragHasFiles == true { fileDragEnded() }
            dragHasFiles = nil
        default:
            break
        }
    }

    func fileDragMoved(to point: CGPoint) {
        let pull = Physics.pull(distance: hypot(point.x - center.x, point.y - center.y), radius: radius)
        if pull > 0 {
            dragIsNear = true
            holeView.setDrag(active: true, pull: pull)
        } else if dragIsNear {
            fileDragEnded()
        }
    }

    func fileDragEnded() {
        guard dragIsNear else { return }
        dragIsNear = false
        holeView.setDrag(active: false, pull: 0)
    }

    // MARK: - Trash

    /// Moves the items to the Trash and starts their fall from `point` (screen coordinates).
    /// Items that cannot be moved are thrown back out.
    func swallow(_ items: [(url: URL, point: CGPoint)]) -> Bool {
        var swallowed = 0
        var failed = false
        for (url, point) in items {
            let offset = CGVector(dx: point.x - center.x, dy: point.y - center.y)
            let icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
            do {
                let item = try trash.moveToTrash(url)
                holeView.addFall(
                    image: icon,
                    from: offset,
                    duration: Physics.fallDuration(bytes: item.size),
                    delay: Double(swallowed) * 0.12
                )
                swallowed += 1
                if item.isDirectory { measure(item) }
            } catch {
                failed = true
                holeView.addEject(image: icon, toward: outward(from: offset))
            }
        }
        if failed { NSSound.beep() }
        updateRadius()
        fileDragEnded()
        return swallowed > 0
    }

    func bringBackLast() {
        do {
            let item = try trash.bringBackLast()
            let icon = NSWorkspace.shared.icon(forFile: item.originalURL.path(percentEncoded: false))
            holeView.addEject(image: icon, toward: towardScreenCenter())
            updateRadius()
        } catch TrashError.nothingToBringBack {
            NSSound.beep()
        } catch {
            NSSound.beep()
            updateRadius()
            let alert = NSAlert()
            alert.messageText = "Could not bring the item back"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }

    func openTrash() {
        guard let url = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first else { return }
        NSWorkspace.shared.open(url)
    }

    /// Measures a folder off the main thread, then grows the hole.
    private func measure(_ item: TrashedItem) {
        let url = item.trashedURL
        Task.detached(priority: .utility) {
            let size = TrashService.diskSize(of: url)
            await MainActor.run { [weak self] in
                self?.trash.setSize(size, forTrashedURL: url)
                self?.updateRadius()
            }
        }
    }

    private func updateRadius() {
        radius = Physics.radius(forMass: trash.totalSize)
        holeView.holeRadius = radius
        layout()
    }

    private func outward(from offset: CGVector) -> CGVector {
        let length = hypot(offset.dx, offset.dy)
        guard length > 1 else { return towardScreenCenter() }
        let distance = Physics.ejectDistance(radius)
        return CGVector(dx: offset.dx / length * distance, dy: offset.dy / length * distance)
    }

    private func towardScreenCenter() -> CGVector {
        let frame = (NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main)?.visibleFrame ?? .zero
        let dx = frame.midX - center.x
        let dy = frame.midY - center.y
        let length = max(1, hypot(dx, dy))
        let distance = Physics.ejectDistance(radius)
        return CGVector(dx: dx / length * distance, dy: dy / length * distance)
    }
}
