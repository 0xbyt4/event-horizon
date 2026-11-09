import HorizonCore
import XCTest

/// These tests use the real Trash. Each test works in its own temporary folder
/// and removes anything it left in the Trash.
final class TrashServiceTests: XCTestCase {
    private var folder: URL!
    private var leftovers: [URL] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EventHorizonTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in leftovers {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeFile(_ name: String, bytes: Int = 4096) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func testMoveToTrashAndBringBack() throws {
        let service = TrashService()
        let file = try makeFile("note.txt")

        let item = try service.moveToTrash(file)
        leftovers.append(item.trashedURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.trashedURL.path))
        XCTAssertEqual(item.name, "note.txt")
        XCTAssertGreaterThanOrEqual(item.size, 4096)
        XCTAssertEqual(service.items.count, 1)
        XCTAssertEqual(service.totalSize, item.size)

        let back = try service.bringBackLast()
        XCTAssertEqual(back, item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.trashedURL.path))
        XCTAssertTrue(service.items.isEmpty)
    }

    func testBringBackIsLastInFirstOut() throws {
        let service = TrashService()
        let first = try service.moveToTrash(try makeFile("a.txt"))
        let second = try service.moveToTrash(try makeFile("b.txt"))
        leftovers += [first.trashedURL, second.trashedURL]

        XCTAssertEqual(try service.bringBackLast().name, "b.txt")
        XCTAssertEqual(try service.bringBackLast().name, "a.txt")
    }

    func testBringBackKeepsItemWhenOriginalLocationIsTaken() throws {
        let service = TrashService()
        let file = try makeFile("report.pdf")
        let item = try service.moveToTrash(file)
        leftovers.append(item.trashedURL)
        _ = try makeFile("report.pdf")

        XCTAssertThrowsError(try service.bringBackLast()) { error in
            XCTAssertEqual(error as? TrashError, .originalLocationTaken("report.pdf"))
        }
        XCTAssertEqual(service.items.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.trashedURL.path))
    }

    func testBringBackDropsItemThatLeftTheTrash() throws {
        let service = TrashService()
        let item = try service.moveToTrash(try makeFile("gone.txt"))
        try FileManager.default.removeItem(at: item.trashedURL)

        XCTAssertThrowsError(try service.bringBackLast()) { error in
            XCTAssertEqual(error as? TrashError, .missingFromTrash("gone.txt"))
        }
        XCTAssertTrue(service.items.isEmpty)
    }

    func testBringBackWithEmptyListFails() {
        XCTAssertThrowsError(try TrashService().bringBackLast()) { error in
            XCTAssertEqual(error as? TrashError, .nothingToBringBack)
        }
    }

    func testFolderSizeIsMeasuredLater() throws {
        let service = TrashService()
        let sub = folder.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: sub.appendingPathComponent("1.jpg"))
        try Data(repeating: 1, count: 20_000).write(to: sub.appendingPathComponent("2.jpg"))

        let item = try service.moveToTrash(sub)
        leftovers.append(item.trashedURL)
        XCTAssertTrue(item.isDirectory)
        XCTAssertEqual(item.size, 0)

        let size = TrashService.diskSize(of: item.trashedURL)
        XCTAssertGreaterThanOrEqual(size, 30_000)
        service.setSize(size, forTrashedURL: item.trashedURL)
        XCTAssertEqual(service.totalSize, size)
    }
}
