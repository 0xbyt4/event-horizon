import AppKit

/// The round area over the hole that accepts dropped files and mouse input.
///
/// macOS sends clicks through fully transparent pixels of a window, so the view fills
/// its circle with an almost invisible color. Outside the circle, clicks reach the windows below.
final class DropTargetView: NSView {
    weak var controller: HorizonController?
    private var dragStart: (mouse: CGPoint, center: CGPoint)?
    private var moved = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.01).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func isInsideCircle(_ point: NSPoint) -> Bool {
        hypot(point.x - bounds.midX, point.y - bounds.midY) <= bounds.width / 2
    }

    // MARK: - Dropping files

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let window {
            controller?.fileDragMoved(to: window.convertPoint(toScreen: sender.draggingLocation))
        }
        guard isInsideCircle(convert(sender.draggingLocation, from: nil)),
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        // Generic or move: the source app must not delete or copy anything. This app moves the files itself.
        let mask = sender.draggingSourceOperationMask
        if mask.contains(.generic) { return .generic }
        if mask.contains(.move) { return .move }
        return []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isInsideCircle(convert(sender.draggingLocation, from: nil))
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty, let window, let controller else { return false }
        let point = window.convertPoint(toScreen: sender.draggingLocation)
        return controller.swallow(urls.map { (url: $0, point: point) })
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        controller?.fileDragEnded()
    }

    // MARK: - Moving the hole and double-click

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        dragStart = (NSEvent.mouseLocation, controller.center)
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let controller else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - start.mouse.x
        let dy = mouse.y - start.mouse.y
        if !moved && hypot(dx, dy) > 3 {
            moved = true
            controller.holeDragBegan()
        }
        if moved {
            controller.moveHole(to: CGPoint(x: start.center.x + dx, y: start.center.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if moved {
            controller?.holeDragEnded()
            controller?.saveCenter()
        } else if event.clickCount == 2 {
            controller?.bringBackLast()
        }
        dragStart = nil
        moved = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.menu
    }
}
