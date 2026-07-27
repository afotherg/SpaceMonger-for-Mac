import Darwin
import Foundation
import SwiftUI

/// Scans a directory tree asynchronously and publishes the result.
@MainActor
final class FolderScanner: ObservableObject {
    @Published var root: FileNode?
    @Published var isScanning = false
    @Published var diskTotal: Int64 = 0
    @Published var diskFree: Int64 = 0
    @Published var treeRevision = 0

    // The generation prevents stale results being published; the token also stops the
    // superseded scan's workers so they do not keep consuming disk bandwidth.
    private var generation = 0
    private var cancellation: ScanCancellation?

    func scan(url: URL) {
        generation += 1
        let gen = generation
        cancellation?.cancel()
        let cancellation = ScanCancellation()
        self.cancellation = cancellation

        isScanning = true
        root = nil

        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path) {
            diskTotal = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
            diskFree = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        }

        Task {
            let node = await Task.detached(priority: .userInitiated) {
                FolderScanner.scanDir(url: url, cancellation: cancellation)
            }.value

            guard self.generation == gen else { return }

            node.sortChildrenBySize()
            self.root = node
            self.treeRevision &+= 1
            self.isScanning = false
            self.cancellation = nil
        }
    }

    func cancel() {
        generation += 1
        cancellation?.cancel()
        cancellation = nil
        isScanning = false
    }

    /// Applies a move to Trash already completed by the caller without rescanning.
    /// When macOS places the item inside the scanned hierarchy, add a relocated copy
    /// at that destination so totals remain accurate.
    @discardableResult
    func moveToTrashInScannedTree(_ node: FileNode, destinationURL: URL?) -> Bool {
        guard let root, let parent = node.parent else { return false }
        let destinationParent = destinationURL.flatMap {
            findNode(at: $0.deletingLastPathComponent(), in: root)
        }
        guard parent.removeChild(node) else { return false }

        if let destinationURL, let destinationParent {
            destinationParent.addChild(node.relocatedCopy(to: destinationURL))
        }
        treeRevision &+= 1
        return true
    }

    private func findNode(at url: URL, in root: FileNode) -> FileNode? {
        let targetPath = url.standardizedFileURL.path
        var pending = [root]
        while let candidate = pending.popLast() {
            if candidate.url.standardizedFileURL.path == targetPath { return candidate }
            pending.append(contentsOf: candidate.children)
        }
        return nil
    }

    // MARK: - Background scanning (no actor isolation)

    /// Scans with bulk directory reads and a fixed-size worker pool. Keeping the pool
    /// bounded improves metadata throughput without creating a task for every folder.
    nonisolated static func scanDir(url: URL) -> FileNode {
        scanDir(url: url, cancellation: ScanCancellation())
    }

    nonisolated private static func scanDir(
        url: URL,
        cancellation: ScanCancellation
    ) -> FileNode {
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let root = FileNode(
            name: name,
            url: url,
            actualSize: 0,
            allocatedSize: 0,
            isDirectory: true,
            modificationDate: modificationDate(atPath: url.path)
        )

        let workQueue = DirectoryWorkQueue()
        workQueue.enqueue(DirectoryWork(url: url, node: root))

        let workerCount = scanWorkerCount(forPath: url.path)
        let group = DispatchGroup()

        for _ in 0..<workerCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let reader = BulkDirectoryReader()
                defer { group.leave() }

                while let work = workQueue.next() {
                    defer { workQueue.complete() }
                    guard !cancellation.isCancelled else {
                        workQueue.cancel()
                        continue
                    }

                    reader.forEachEntry(atPath: work.url.path) { entry in
                        guard !cancellation.isCancelled else { return false }

                        let childURL = work.url.appendingPathComponent(
                            entry.name,
                            isDirectory: entry.isDirectory
                        )
                        let child = FileNode(
                            name: entry.name,
                            url: childURL,
                            actualSize: entry.isDirectory ? 0 : entry.logicalSize,
                            allocatedSize: entry.isDirectory ? 0 : entry.allocatedSize,
                            isDirectory: entry.isDirectory,
                            modificationDate: entry.modificationDate
                        )
                        child.parent = work.node
                        work.node.children.append(child)

                        if entry.isDirectory {
                            workQueue.enqueue(DirectoryWork(url: childURL, node: child))
                        }
                        return true
                    }
                }
            }
        }

        group.wait()
        return root
    }

    nonisolated private static func modificationDate(atPath path: String) -> Date? {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return nil }
        let timestamp = info.st_mtimespec
        return Date(
            timeIntervalSince1970: TimeInterval(timestamp.tv_sec)
                + TimeInterval(timestamp.tv_nsec) / 1_000_000_000
        )
    }

    nonisolated private static func scanWorkerCount(forPath path: String) -> Int {
        if let configured = ProcessInfo.processInfo.environment["SPACEMONGER_SCAN_WORKERS"],
           let value = Int(configured) {
            return max(1, value)
        }

        var info = statfs()
        let isNetworkFileSystem: Bool
        if statfs(path, &info) == 0 {
            let type = withUnsafePointer(to: &info.f_fstypename) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 16) {
                    String(cString: $0)
                }
            }
            isNetworkFileSystem = ["smbfs", "nfs", "afpfs", "webdavfs"].contains(type)
        } else {
            isNetworkFileSystem = false
        }

        return isNetworkFileSystem
            ? 4
            : min(8, max(4, ProcessInfo.processInfo.activeProcessorCount))
    }
}

private final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private struct DirectoryWork {
    let url: URL
    let node: FileNode
}

/// A shared LIFO queue keeps workers busy even when one directory branch is shallow.
private final class DirectoryWorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [DirectoryWork] = []
    private var active = 0
    private var closed = false

    func enqueue(_ work: DirectoryWork) {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return }
        pending.append(work)
        condition.signal()
    }

    func next() -> DirectoryWork? {
        condition.lock()
        defer { condition.unlock() }

        while pending.isEmpty && !closed {
            if active == 0 {
                closed = true
                condition.broadcast()
                return nil
            }
            condition.wait()
        }

        guard let work = pending.popLast() else { return nil }
        active += 1
        return work
    }

    func complete() {
        condition.lock()
        defer { condition.unlock() }
        active -= 1
        if pending.isEmpty && active == 0 {
            closed = true
            condition.broadcast()
        }
    }

    func cancel() {
        condition.lock()
        pending.removeAll(keepingCapacity: true)
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}

private struct BulkDirectoryEntry {
    let name: String
    let isDirectory: Bool
    let logicalSize: Int64
    let allocatedSize: Int64
    let modificationDate: Date?
}

/// Reads many directory entries and their metadata in each kernel call.
private final class BulkDirectoryReader {
    private static let bufferSize = 256 * 1024
    private let buffer = UnsafeMutableRawPointer.allocate(
        byteCount: BulkDirectoryReader.bufferSize,
        alignment: 16
    )

    deinit {
        buffer.deallocate()
    }

    @discardableResult
    func forEachEntry(atPath path: String, _ body: (BulkDirectoryEntry) -> Bool) -> Bool {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = requestedCommonAttributes
        attributes.fileattr = requestedFileAttributes

        var receivedBulkEntries = false
        while true {
            let count = getattrlistbulk(
                descriptor,
                &attributes,
                buffer,
                Self.bufferSize,
                UInt64(FSOPT_PACK_INVAL_ATTRS)
            )
            if count == 0 { return true }
            guard count > 0 else {
                // Some external and network filesystems do not implement the bulk
                // syscall. Fall back only before emitting anything, avoiding duplicates
                // if a filesystem fails partway through an enumeration.
                return receivedBulkEntries ? false : forEachFoundationEntry(atPath: path, body)
            }
            receivedBulkEntries = true

            let bufferEnd = buffer.advanced(by: Self.bufferSize)
            var entryPointer = buffer

            for _ in 0..<count {
                guard entryPointer.advanced(by: MemoryLayout<UInt32>.size) <= bufferEnd else {
                    return false
                }
                let entryLength = Int(entryPointer.loadUnaligned(as: UInt32.self))
                guard entryLength >= commonAttributesEnd,
                      entryPointer.advanced(by: entryLength) <= bufferEnd else {
                    return false
                }

                let nextEntry = entryPointer.advanced(by: entryLength)
                defer { entryPointer = nextEntry }

                let objectType = entryPointer
                    .advanced(by: objectTypeOffset)
                    .loadUnaligned(as: UInt32.self)
                if objectType == VLNK.rawValue { continue }

                guard let name = entryName(from: entryPointer, length: entryLength),
                      name != ".", name != ".." else { continue }

                let isDirectory = objectType == VDIR.rawValue
                let returnedCommon = entryPointer
                    .advanced(by: returnedCommonAttributesOffset)
                    .loadUnaligned(as: attrgroup_t.self)
                let returnedFile = entryPointer
                    .advanced(by: returnedFileAttributesOffset)
                    .loadUnaligned(as: attrgroup_t.self)

                let modificationDate: Date?
                if returnedCommon & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    let timestamp = entryPointer
                        .advanced(by: modificationTimeOffset)
                        .loadUnaligned(as: timespec.self)
                    modificationDate = Date(
                        timeIntervalSince1970: TimeInterval(timestamp.tv_sec)
                            + TimeInterval(timestamp.tv_nsec) / 1_000_000_000
                    )
                } else {
                    modificationDate = nil
                }

                var logicalSize: Int64 = 0
                var allocatedSize: Int64 = 0
                if !isDirectory, entryLength >= fileDataOffset + 2 * MemoryLayout<off_t>.size {
                    let allocation = entryPointer
                        .advanced(by: fileDataOffset)
                        .loadUnaligned(as: off_t.self)
                    let logical = entryPointer
                        .advanced(by: fileDataOffset + MemoryLayout<off_t>.size)
                        .loadUnaligned(as: off_t.self)
                    logicalSize = max(0, Int64(logical))
                    allocatedSize = returnedFile & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0
                        ? max(0, Int64(allocation))
                        : logicalSize
                }

                if !body(BulkDirectoryEntry(
                    name: name,
                    isDirectory: isDirectory,
                    logicalSize: logicalSize,
                    allocatedSize: allocatedSize,
                    modificationDate: modificationDate
                )) {
                    return true
                }
            }
        }
    }

    private func forEachFoundationEntry(
        atPath path: String,
        _ body: (BulkDirectoryEntry) -> Bool
    ) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
        ]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: Array(keys)
        ) else { return false }

        for item in items {
            guard let values = try? item.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else { continue }
            let isDirectory = values.isDirectory == true
            if !body(BulkDirectoryEntry(
                name: item.lastPathComponent,
                isDirectory: isDirectory,
                logicalSize: isDirectory ? 0 : Int64(values.fileSize ?? 0),
                allocatedSize: isDirectory
                    ? 0
                    : Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0),
                modificationDate: values.contentModificationDate
            )) {
                break
            }
        }
        return true
    }
}

private let requestedCommonAttributes: attrgroup_t =
    attrgroup_t(ATTR_CMN_RETURNED_ATTRS) |
    attrgroup_t(ATTR_CMN_NAME) |
    attrgroup_t(ATTR_CMN_DEVID) |
    attrgroup_t(ATTR_CMN_OBJTYPE) |
    attrgroup_t(ATTR_CMN_MODTIME) |
    attrgroup_t(ATTR_CMN_FILEID)

private let requestedFileAttributes: attrgroup_t =
    attrgroup_t(ATTR_FILE_LINKCOUNT) |
    attrgroup_t(ATTR_FILE_ALLOCSIZE) |
    attrgroup_t(ATTR_FILE_DATALENGTH)

private let returnedCommonAttributesOffset = 4
private let returnedFileAttributesOffset = 16
private let nameOffset = 24
private let objectTypeOffset = 36
private let modificationTimeOffset = 40
private let commonAttributesEnd = 64
private let fileDataOffset = 68

private func entryName(from entry: UnsafeRawPointer, length: Int) -> String? {
    let reference = entry.advanced(by: nameOffset)
    let relativeOffset = Int(reference.loadUnaligned(as: Int32.self))
    let byteCount = Int(reference.advanced(by: 4).loadUnaligned(as: UInt32.self))
    let start = nameOffset + relativeOffset

    guard byteCount > 1,
          start >= 0,
          start + byteCount <= length else { return nil }

    let bytes = reference.advanced(by: relativeOffset)
    guard bytes.advanced(by: byteCount - 1).load(as: UInt8.self) == 0 else { return nil }
    return String(decoding: UnsafeBufferPointer(
        start: bytes.assumingMemoryBound(to: UInt8.self),
        count: byteCount - 1
    ), as: UTF8.self)
}
