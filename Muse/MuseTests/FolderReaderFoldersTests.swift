import XCTest
@testable import Muse

final class FolderReaderFoldersTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-reader-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.jpg"))
        try fm.createDirectory(at: dir.appendingPathComponent("Sub"),
                               withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testExcludesFoldersByDefault() {
        let nodes = FolderReader.files(in: dir)
        XCTAssertEqual(nodes.map { $0.url.lastPathComponent }, ["a.jpg"])
    }

    func testIncludesFoldersWhenRequested() {
        let nodes = FolderReader.files(in: dir, includeFolders: true)
        let names = Set(nodes.map { $0.url.lastPathComponent })
        XCTAssertEqual(names, ["a.jpg", "Sub"])
        let sub = nodes.first { $0.url.lastPathComponent == "Sub" }
        XCTAssertEqual(sub?.kind, .folder)
    }
}
