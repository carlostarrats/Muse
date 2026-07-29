import XCTest
@testable import Muse

final class FolderStatTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testComputeImmediateRecursiveSizeLatest() throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        try Data([1, 2, 3]).write(to: root.appendingPathComponent("a.txt"))   // 3 bytes
        try Data([1, 2]).write(to: root.appendingPathComponent("b.txt"))      // 2 bytes
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let deep = sub.appendingPathComponent("c.txt")
        try Data([1, 2, 3, 4]).write(to: deep)                                // 4 bytes
        let newest = Date().addingTimeInterval(120)
        try fm.setAttributes([.modificationDate: newest], ofItemAtPath: deep.path)

        let stat = FolderStats.compute(folder: root)
        XCTAssertEqual(stat.immediateFileCount, 3)   // a.txt, b.txt + sub (folders now counted)
        XCTAssertEqual(stat.recursiveFileCount, 3)   // + c.txt
        XCTAssertEqual(stat.totalSize, 9)
        XCTAssertNotNil(stat.latestModified)
        XCTAssertEqual(stat.latestModified!.timeIntervalSince1970,
                       newest.timeIntervalSince1970, accuracy: 2)
    }

    func testComputeEmptyFolder() throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let stat = FolderStats.compute(folder: root)
        XCTAssertEqual(stat.immediateFileCount, 0)
        XCTAssertEqual(stat.recursiveFileCount, 0)
        XCTAssertEqual(stat.totalSize, 0)
        XCTAssertNil(stat.latestModified)
    }

    func testRootContainingLongestMatch() {
        let a = URL(fileURLWithPath: "/Users/x/Photos")
        let b = URL(fileURLWithPath: "/Users/x/Photos/2024")
        XCTAssertEqual(FolderStats.root(containing: "/Users/x/Photos/2024/img.jpg", in: [a, b]), b)
        XCTAssertEqual(FolderStats.root(containing: "/Users/x/Photos/old.jpg", in: [a, b]), a)
        XCTAssertNil(FolderStats.root(containing: "/Users/y/z.jpg", in: [a, b]))
    }

    /// A folder that cannot be listed must report `reachable: false` and a nil
    /// KNOWN count. Zero counts from a failed listing are structurally
    /// indistinguishable from an empty folder, and "0 files" is a decision
    /// input: the iCloud sidebar row hides itself on `.empty`, so an
    /// unlistable container used to hide a folder that may be full.
    func testUnreadableFolderIsUnreachableNotEmpty() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MuseStatProbe-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("a.txt"))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? fm.removeItem(at: root)
        }

        let stat = FolderStats.compute(folder: root)
        XCTAssertFalse(stat.reachable)
        XCTAssertNil(stat.knownRecursiveFileCount)
        // And the gate that consumes it must say "unknown", never "empty".
        XCTAssertEqual(
            ICloudSidebarVisibility.presence(configured: true,
                                             recursiveFileCount: stat.knownRecursiveFileCount),
            .unknown)
        XCTAssertTrue(ICloudSidebarVisibility.rowVisible(.unknown, showSetting: false),
                      "an unlistable folder must keep showing, not vanish")
    }

    /// The counterpart: a genuinely empty, readable folder still reports empty.
    func testReadableEmptyFolderIsReachableAndZero() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MuseStatProbe-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let stat = FolderStats.compute(folder: root)
        XCTAssertTrue(stat.reachable)
        XCTAssertEqual(stat.knownRecursiveFileCount, 0)
        XCTAssertEqual(
            ICloudSidebarVisibility.presence(configured: true,
                                             recursiveFileCount: stat.knownRecursiveFileCount),
            .empty)
    }
}
