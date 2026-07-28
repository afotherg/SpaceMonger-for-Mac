import Foundation
import XCTest
@testable import SpaceMonger

final class FolderScannerTests: XCTestCase {
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
