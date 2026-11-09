import CoreGraphics
import Foundation

/// A file icon on the desktop.
public struct DesktopItem: Equatable, Sendable {
    public let url: URL
    /// Center of the icon in AppKit screen coordinates (origin at the bottom left of the main screen).
    public let center: CGPoint

    public init(url: URL, center: CGPoint) {
        self.url = url
        self.center = center
    }
}

/// Finds the desktop icons that a moving hole catches.
public enum DesktopSweep {
    /// Parses Finder output with one item per line: `file URL <tab> x <tab> y`.
    ///
    /// Finder gives the icon center in points, with y measured down from the top of the
    /// main screen. Only items directly inside `desktopFolder` are kept, so disks and
    /// other locations shown on the desktop are never returned.
    public static func parse(_ output: String, mainScreenHeight: CGFloat, desktopFolder: URL) -> [DesktopItem] {
        let folder = desktopFolder.standardizedFileURL.resolvingSymlinksInPath().path
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let url = URL(string: String(fields[0])), url.isFileURL,
                  let x = Double(fields[1]), let y = Double(fields[2]) else { return nil }
            let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            guard parent == folder else { return nil }
            return DesktopItem(url: url, center: CGPoint(x: x, y: mainScreenHeight - y))
        }
    }

    /// The items whose icon center is inside the capture radius of a hole at `center`.
    public static func captured(_ items: [DesktopItem], center: CGPoint, radius: CGFloat) -> [DesktopItem] {
        let capture = Physics.captureRadius(radius)
        return items.filter { hypot($0.center.x - center.x, $0.center.y - center.y) <= capture }
    }
}
