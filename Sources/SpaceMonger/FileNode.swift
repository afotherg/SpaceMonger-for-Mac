import Foundation

enum SizeMetric: String, CaseIterable, Identifiable, Sendable {
    case allocated
    case logical

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// Represents a file or directory in the scanned tree.
/// Mirrors the CFolder struct from the original Windows code, adapted for Swift/macOS.
// Nodes are assembled by scanner workers before the completed tree is handed to the
// main actor. Each worker owns the node it mutates, and published trees are read-only
// apart from main-actor sorting and size caching.
final class FileNode: Identifiable, @unchecked Sendable {
    let id = UUID()
    let name: String
    let url: URL
    let actualSize: Int64     // real file size in bytes
    private(set) var allocatedSize: Int64  // counted size on disk
    let isDirectory: Bool
    let modificationDate: Date?
    /// Another path owns this file object's allocated bytes when it is a hard link.
    private(set) var storageOwnerURL: URL?
    let fileIdentity: FileIdentity?

    var children: [FileNode] = []
    weak var parent: FileNode?

    // Cached total size to avoid recomputation
    private var _totalSize: Int64 = -1
    private var _logicalTotalSize: Int64 = -1
    private var _fileCount = -1
    private var _folderCount = -1

    init(
        name: String,
        url: URL,
        actualSize: Int64,
        allocatedSize: Int64,
        isDirectory: Bool,
        modificationDate: Date? = nil,
        storageOwnerURL: URL? = nil,
        fileIdentity: FileIdentity? = nil
    ) {
        self.name = name
        self.url = url
        self.actualSize = actualSize
        self.allocatedSize = allocatedSize
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.storageOwnerURL = storageOwnerURL
        self.fileIdentity = fileIdentity
    }

    /// Recursive total size of this node and all descendants.
    /// For files, returns allocatedSize. For directories, sums children.
    var totalSize: Int64 {
        if _totalSize >= 0 { return _totalSize }
        if isDirectory {
            _totalSize = children.reduce(0) { $0 + $1.totalSize }
        } else {
            _totalSize = allocatedSize
        }
        return _totalSize
    }

    /// Recursive logical byte count. Unlike allocated size, each directory entry
    /// contributes its reported file length, including additional hard links.
    var logicalTotalSize: Int64 {
        if _logicalTotalSize >= 0 { return _logicalTotalSize }
        if isDirectory {
            _logicalTotalSize = children.reduce(0) { $0 + $1.logicalTotalSize }
        } else {
            _logicalTotalSize = actualSize
        }
        return _logicalTotalSize
    }

    func size(for metric: SizeMetric) -> Int64 {
        switch metric {
        case .allocated: return totalSize
        case .logical: return logicalTotalSize
        }
    }

    /// Sort children by totalSize descending at every level.
    /// The original uses an 8-bit radix sort (O(n)); we use Swift's timsort (O(n log n))
    /// which is fast enough for filesystem counts in practice.
    func sortChildrenBySize() {
        children.sort { $0.totalSize > $1.totalSize }
        children.forEach { $0.sortChildrenBySize() }

        // Populate both size caches before the tree is published to readers.
        _ = logicalTotalSize

        if isDirectory {
            _fileCount = children.reduce(0) { $0 + $1.fileCount }
            _folderCount = children.reduce(0) {
                $0 + ($1.isDirectory ? 1 : 0) + $1.folderCount
            }
        } else {
            _fileCount = 1
            _folderCount = 0
        }
    }

    /// Removes one direct child and refreshes cached totals through the root.
    /// Returns false when the node is no longer a child of this directory.
    @discardableResult
    func removeChild(_ child: FileNode) -> Bool {
        guard let index = children.firstIndex(where: { $0 === child }) else { return false }
        children.remove(at: index)
        child.parent = nil
        refreshCachedAggregatesUpward()
        return true
    }

    /// Adds a direct child and refreshes cached totals through the root.
    func addChild(_ child: FileNode) {
        child.parent = self
        children.append(child)
        refreshCachedAggregatesUpward()
    }

    /// Copies a node hierarchy at a new filesystem location. Trash may rename an
    /// item to avoid a collision, so the destination URL is authoritative.
    func relocatedCopy(to destinationURL: URL) -> FileNode {
        let copy = FileNode(
            name: destinationURL.lastPathComponent,
            url: destinationURL,
            actualSize: actualSize,
            allocatedSize: allocatedSize,
            isDirectory: isDirectory,
            modificationDate: modificationDate,
            storageOwnerURL: storageOwnerURL,
            fileIdentity: fileIdentity
        )
        copy.children = children.map { child in
            let childCopy = child.relocatedCopy(
                to: destinationURL.appendingPathComponent(
                    child.name,
                    isDirectory: child.isDirectory
                )
            )
            childCopy.parent = copy
            return childCopy
        }
        copy.sortChildrenBySize()
        return copy
    }

    /// Makes a previously uncounted hard link own the shared file allocation.
    func takeStorageOwnership(allocatedSize: Int64) {
        guard !isDirectory else { return }
        self.allocatedSize = allocatedSize
        storageOwnerURL = nil
        refreshCachedAggregatesUpward()
    }

    private func refreshCachedAggregatesUpward() {
        if isDirectory {
            children.sort { $0.totalSize > $1.totalSize }
            _totalSize = children.reduce(0) { $0 + $1.totalSize }
            _logicalTotalSize = children.reduce(0) { $0 + $1.logicalTotalSize }
            _fileCount = children.reduce(0) { $0 + $1.fileCount }
            _folderCount = children.reduce(0) {
                $0 + ($1.isDirectory ? 1 : 0) + $1.folderCount
            }
        } else {
            _totalSize = allocatedSize
            _logicalTotalSize = actualSize
            _fileCount = 1
            _folderCount = 0
        }
        parent?.refreshCachedAggregatesUpward()
    }

    var formattedSize: String { formatBytes(totalSize) }

    func formattedSize(for metric: SizeMetric) -> String {
        formatBytes(size(for: metric))
    }

    var fileCount: Int {
        if _fileCount >= 0 { return _fileCount }
        _fileCount = isDirectory ? children.reduce(0) { $0 + $1.fileCount } : 1
        return _fileCount
    }

    var folderCount: Int {
        if _folderCount >= 0 { return _folderCount }
        _folderCount = isDirectory
            ? children.reduce(0) { $0 + ($1.isDirectory ? 1 : 0) + $1.folderCount }
            : 0
        return _folderCount
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let kb: Int64 = 1_024
    let mb = kb * 1_024
    let gb = mb * 1_024
    let tb = gb * 1_024
    switch bytes {
    case ..<kb: return "\(bytes) B"
    case ..<mb: return String(format: "%.1f KB", Double(bytes) / Double(kb))
    case ..<gb: return String(format: "%.1f MB", Double(bytes) / Double(mb))
    case ..<tb: return String(format: "%.2f GB", Double(bytes) / Double(gb))
    default:    return String(format: "%.2f TB", Double(bytes) / Double(tb))
    }
}
