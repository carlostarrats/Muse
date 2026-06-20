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
}
