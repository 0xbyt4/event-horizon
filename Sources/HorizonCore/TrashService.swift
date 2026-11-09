import Foundation

/// One item that the hole moved to the Trash.
public struct TrashedItem: Equatable, Sendable {
    public let name: String
    public let originalURL: URL
    public let trashedURL: URL
    public let isDirectory: Bool
    /// Bytes on disk. For a folder this is 0 until `TrashService.setSize` fills it in.
    public var size: Int64
}

public enum TrashError: LocalizedError, Equatable {
    case nothingToBringBack
    case missingFromTrash(String)
    case originalLocationTaken(String)
    case noTrashLocation(String)

    public var errorDescription: String? {
        switch self {
        case .nothingToBringBack:
            "There is nothing to bring back."
        case .missingFromTrash(let name):
            "“\(name)” is no longer in the Trash. It was emptied or moved."
        case .originalLocationTaken(let name):
            "An item named “\(name)” already exists in its original folder. Move or rename that item, then try again."
        case .noTrashLocation(let name):
            "“\(name)” was moved to the Trash, but macOS did not report where. Find it in the Trash with Finder."
        }
    }
}

/// Moves items to the Trash and brings them back, last in first out.
/// It never deletes anything permanently.
public final class TrashService {
    public private(set) var items: [TrashedItem] = []
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Total size of the items that can still be brought back.
    public var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    /// Moves the item at `url` to the Trash and remembers it so it can be brought back.
    @discardableResult
    public func moveToTrash(_ url: URL) throws -> TrashedItem {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        // Folders can hold many files, so their size is measured later, off the main thread.
        let size = isDirectory ? 0 : Self.diskSize(of: url)

        var resultingURL: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let trashedURL = resultingURL as URL? else {
            throw TrashError.noTrashLocation(url.lastPathComponent)
        }

        let item = TrashedItem(
            name: url.lastPathComponent,
            originalURL: url,
            trashedURL: trashedURL,
            isDirectory: isDirectory,
            size: size
        )
        items.append(item)
        return item
    }

    /// Moves the most recent item back to its original location.
    /// When the original location is taken, the item stays in the Trash and in the list.
    @discardableResult
    public func bringBackLast() throws -> TrashedItem {
        guard let item = items.last else { throw TrashError.nothingToBringBack }
        guard fileManager.fileExists(atPath: item.trashedURL.path(percentEncoded: false)) else {
            items.removeLast()
            throw TrashError.missingFromTrash(item.name)
        }
        guard !fileManager.fileExists(atPath: item.originalURL.path(percentEncoded: false)) else {
            throw TrashError.originalLocationTaken(item.name)
        }
        try fileManager.moveItem(at: item.trashedURL, to: item.originalURL)
        items.removeLast()
        return item
    }

    /// Stores the measured size of a folder that was moved to the Trash.
    public func setSize(_ size: Int64, forTrashedURL url: URL) {
        guard let index = items.firstIndex(where: { $0.trashedURL == url }) else { return }
        items[index].size = size
    }

    /// Bytes the item uses on disk. For a folder, counts at most `limit` entries.
    public static func diskSize(of url: URL, limit: Int = 50_000) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let values = try? url.resourceValues(forKeys: keys)
        guard values?.isDirectory == true else {
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }
        var total: Int64 = 0
        var count = 0
        for case let child as URL in enumerator {
            guard count < limit else { break }
            count += 1
            let childValues = try? child.resourceValues(forKeys: keys)
            total += Int64(childValues?.totalFileAllocatedSize ?? childValues?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
