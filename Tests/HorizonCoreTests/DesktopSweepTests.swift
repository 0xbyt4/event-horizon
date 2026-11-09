import CoreGraphics
import HorizonCore
import XCTest

final class DesktopSweepTests: XCTestCase {
    private let desktop = URL(fileURLWithPath: "/Users/test/Desktop", isDirectory: true)

    func testParseConvertsFinderPositionsToScreenCoordinates() {
        let output = "file:///Users/test/Desktop/Report%20Final.pdf\t1990\t297\nfile:///Users/test/Desktop/Folder/\t100\t1000\n"
        let items = DesktopSweep.parse(output, mainScreenHeight: 1329, desktopFolder: desktop)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].url.lastPathComponent, "Report Final.pdf")
        XCTAssertEqual(items[0].center, CGPoint(x: 1990, y: 1032))
        XCTAssertEqual(items[1].url.lastPathComponent, "Folder")
        XCTAssertEqual(items[1].center, CGPoint(x: 100, y: 329))
    }

    func testParseKeepsOnlyItemsDirectlyInTheDesktopFolder() {
        let output = [
            "file:///\t1900\t60",
            "file:///Volumes/Backup/\t1900\t160",
            "file:///Users/test/Documents/notes.txt\t1900\t260",
            "file:///Users/test/Desktop/Folder/inner.txt\t1900\t360",
            "file:///Users/test/Desktop/keep.txt\t1900\t460",
            "not a line",
        ].joined(separator: "\n")
        let items = DesktopSweep.parse(output, mainScreenHeight: 1000, desktopFolder: desktop)

        XCTAssertEqual(items.map(\.url.lastPathComponent), ["keep.txt"])
    }

    func testCapturedReturnsItemsInsideCaptureRadiusOnly() {
        let radius: CGFloat = 22
        let capture = Physics.captureRadius(radius)
        let center = CGPoint(x: 500, y: 500)
        let inside = DesktopItem(url: desktop.appendingPathComponent("a"), center: CGPoint(x: 500 + capture - 1, y: 500))
        let outside = DesktopItem(url: desktop.appendingPathComponent("b"), center: CGPoint(x: 500, y: 500 + capture + 1))

        XCTAssertEqual(DesktopSweep.captured([inside, outside], center: center, radius: radius), [inside])
    }
}
