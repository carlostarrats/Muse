import XCTest
@testable import Muse

final class FolderStatCountTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-statcount-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 3 immediate files
        for n in ["a.jpg", "b.pdf", "c.txt"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(n))
        }
        // 2 immediate subfolders, each with 1 file inside
        for f in ["Sub1", "Sub2"] {
            let sub = dir.appendingPathComponent(f)
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data("y".utf8).write(to: sub.appendingPathComponent("inside.jpg"))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testImmediateCountIncludesSubfolders() {
        let stat = FolderStats.compute(folder: dir)
        // 3 files + 2 subfolders = 5
        XCTAssertEqual(stat.immediateFileCount, 5)
    }

    func testRecursiveCountIsFilesOnly() {
        let stat = FolderStats.compute(folder: dir)
        // 3 immediate files + 2 files inside subfolders = 5 files; folders not counted
        XCTAssertEqual(stat.recursiveFileCount, 5)
    }
}
