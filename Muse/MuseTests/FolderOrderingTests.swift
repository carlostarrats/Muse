import XCTest
@testable import Muse

final class FolderOrderingTests: XCTestCase {
    private func node(_ name: String, _ kind: AssetKind) -> FileNode {
        FileNode(url: URL(fileURLWithPath: "/tmp/\(name)"), kind: kind)
    }

    func testFoldersComeFirstPreservingOrder() {
        let input = [node("a.jpg", .image), node("F1", .folder),
                     node("b.pdf", .pdf), node("F2", .folder)]
        let out = FolderOrdering.foldersFirst(input)
        XCTAssertEqual(out.map { $0.url.lastPathComponent },
                       ["F1", "F2", "a.jpg", "b.pdf"])
    }

    func testStableWithinEachGroup() {
        // Folders keep their incoming relative order; so do files.
        let input = [node("F2", .folder), node("z.jpg", .image),
                     node("F1", .folder), node("a.jpg", .image)]
        let out = FolderOrdering.foldersFirst(input)
        XCTAssertEqual(out.map { $0.url.lastPathComponent },
                       ["F2", "F1", "z.jpg", "a.jpg"])
    }

    func testAllFilesUnchanged() {
        let input = [node("a.jpg", .image), node("b.pdf", .pdf)]
        XCTAssertEqual(FolderOrdering.foldersFirst(input).map { $0.url.lastPathComponent },
                       ["a.jpg", "b.pdf"])
    }

    func testAllFolders() {
        let input = [node("F1", .folder), node("F2", .folder)]
        XCTAssertEqual(FolderOrdering.foldersFirst(input).map { $0.url.lastPathComponent },
                       ["F1", "F2"])
    }

    func testEmpty() {
        XCTAssertTrue(FolderOrdering.foldersFirst([]).isEmpty)
    }
}
