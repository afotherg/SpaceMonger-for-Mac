import Foundation
import XCTest
@testable import SpaceMonger

final class FolderScannerTests: XCTestCase {
    func testSizeMetricSelectsAllocatedOrLogicalTotals() {
        let root = FileNode(
            name: "root",
            url: URL(fileURLWithPath: "/root"),
            actualSize: 0,
            allocatedSize: 0,
            isDirectory: true
        )
        let first = FileNode(
            name: "first",
            url: URL(fileURLWithPath: "/root/first"),
            actualSize: 1_000,
            allocatedSize: 4_096,
            isDirectory: false
        )
        let second = FileNode(
            name: "second",
            url: URL(fileURLWithPath: "/root/second"),
            actualSize: 2_000,
            allocatedSize: 0,
            isDirectory: false
        )
        root.addChild(first)
        root.addChild(second)

        XCTAssertEqual(root.size(for: .allocated), 4_096)
        XCTAssertEqual(root.size(for: .logical), 3_000)
    }

    func testMountPolicyExcludesLiteralMountsButNotFirmlinkPaths() {
        let policy = ScanBoundaryPolicy(
            scanRootURL: URL(fileURLWithPath: "/", isDirectory: true),
            mountedPaths: [
                "/",
                "/System/Volumes/Data",
                "/System/Volumes/VM",
                "/Volumes/External",
            ]
        )

        XCTAssertFalse(policy.excludes(URL(fileURLWithPath: "/", isDirectory: true)))
        XCTAssertFalse(policy.excludes(URL(fileURLWithPath: "/Users", isDirectory: true)))
        XCTAssertTrue(policy.excludes(URL(
            fileURLWithPath: "/System/Volumes/Data",
            isDirectory: true
        )))
        XCTAssertTrue(policy.excludes(URL(
            fileURLWithPath: "/Volumes/External",
            isDirectory: true
        )))
    }

    func testExplicitlySelectedMountRootIsAllowed() {
        let selectedMount = URL(
            fileURLWithPath: "/Volumes/External",
            isDirectory: true
        )
        let policy = ScanBoundaryPolicy(
            scanRootURL: selectedMount,
            mountedPaths: ["/", selectedMount.path]
        )

        XCTAssertFalse(policy.excludes(selectedMount))
    }

    func testHardLinkedFileAllocationIsCountedOnce() throws {
        let directory = try makeHardLinkFixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = FolderScanner.scanDir(url: directory)
        let files = root.children.filter { !$0.isDirectory }

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files.filter { $0.allocatedSize > 0 }.count, 1)
        XCTAssertEqual(files.filter { $0.storageOwnerURL != nil }.count, 1)
        XCTAssertEqual(root.totalSize, files.map(\.allocatedSize).max() ?? 0)
    }

    @MainActor
    func testRemovingOwningHardLinkTransfersStorageOwnership() throws {
        let directory = try makeHardLinkFixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = FolderScanner.scanDir(url: directory)
        let originalTotal = root.totalSize
        let owningNode = try XCTUnwrap(root.children.first { $0.allocatedSize > 0 })
        let scanner = FolderScanner()
        scanner.root = root

        XCTAssertTrue(scanner.moveToTrashInScannedTree(owningNode, destinationURL: nil))
        let remainingNode = try XCTUnwrap(root.children.first)
        XCTAssertEqual(root.children.count, 1)
        XCTAssertEqual(root.totalSize, originalTotal)
        XCTAssertEqual(remainingNode.allocatedSize, originalTotal)
        XCTAssertNil(remainingNode.storageOwnerURL)
    }

    @MainActor
    func testPreparedTrashUpdateRelocatesHierarchyInsideScannedTree() async throws {
        let root = FileNode(
            name: "root",
            url: URL(fileURLWithPath: "/root", isDirectory: true),
            actualSize: 0,
            allocatedSize: 0,
            isDirectory: true
        )
        let trash = FileNode(
            name: ".Trash",
            url: URL(fileURLWithPath: "/root/.Trash", isDirectory: true),
            actualSize: 0,
            allocatedSize: 0,
            isDirectory: true
        )
        let folder = FileNode(
            name: "folder",
            url: URL(fileURLWithPath: "/root/folder", isDirectory: true),
            actualSize: 0,
            allocatedSize: 0,
            isDirectory: true
        )
        let file = FileNode(
            name: "file.bin",
            url: URL(fileURLWithPath: "/root/folder/file.bin"),
            actualSize: 1_024,
            allocatedSize: 4_096,
            isDirectory: false
        )
        folder.addChild(file)
        root.addChild(folder)
        root.addChild(trash)
        root.sortChildrenBySize()

        let originalTotal = root.totalSize
        let scanner = FolderScanner()
        scanner.root = root
        var progressValues: [Int] = []
        let destination = URL(fileURLWithPath: "/root/.Trash/folder", isDirectory: true)

        let update = await scanner.prepareMoveToTrashInScannedTree(
            folder,
            destinationURL: destination,
            progress: { progressValues.append($0) }
        )
        XCTAssertTrue(scanner.applyTrashTreeUpdate(try XCTUnwrap(update)))

        let relocated = try XCTUnwrap(trash.children.first)
        XCTAssertEqual(relocated.url, destination)
        XCTAssertEqual(relocated.children.first?.url.path, "/root/.Trash/folder/file.bin")
        XCTAssertEqual(root.totalSize, originalTotal)
        XCTAssertEqual(progressValues.last, 2)
        XCTAssertFalse(root.children.contains { $0 === folder })
    }

    func testRelocatedCopyUpdatesHardLinkOwnerPathInsideMovedHierarchy() throws {
        let identity = FileIdentity(deviceID: 1, fileID: 42)
        let folder = FileNode(
            name: "folder",
            url: URL(fileURLWithPath: "/root/folder", isDirectory: true),
            actualSize: 0,
            allocatedSize: 0,
            isDirectory: true
        )
        let owner = FileNode(
            name: "owner",
            url: URL(fileURLWithPath: "/root/folder/owner"),
            actualSize: 10,
            allocatedSize: 4_096,
            isDirectory: false,
            fileIdentity: identity,
            linkCount: 2
        )
        let link = FileNode(
            name: "link",
            url: URL(fileURLWithPath: "/root/folder/link"),
            actualSize: 10,
            allocatedSize: 0,
            isDirectory: false,
            storageOwnerURL: owner.url,
            fileIdentity: identity,
            linkCount: 2
        )
        folder.addChild(owner)
        folder.addChild(link)
        folder.sortChildrenBySize()

        let copy = folder.relocatedCopy(
            to: URL(fileURLWithPath: "/root/.Trash/folder", isDirectory: true)
        )
        let copiedLink = try XCTUnwrap(copy.children.first { $0.name == "link" })

        XCTAssertEqual(copiedLink.storageOwnerURL?.path, "/root/.Trash/folder/owner")
    }

    private func makeHardLinkFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpaceMongerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )

        let original = directory.appendingPathComponent("original.bin")
        let hardLink = directory.appendingPathComponent("hard-link.bin")
        try Data(repeating: 0x5a, count: 64 * 1_024).write(to: original)
        try FileManager.default.linkItem(at: original, to: hardLink)
        return directory
    }
}
