import XCTest
@testable import Muse

/// Pure-logic tests for the FSEvents → "media files worth refreshing" filter.
/// No disk access: AssetKind.detect classifies non-existent paths by extension.
final class FolderEventFilterTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/Users/me/Pictures/Inspo")

    func testKeepsDirectChildImage() {
        let changed = FolderEventFilter.mediaChanges(
            paths: ["/Users/me/Pictures/Inspo/shot.png"],
            folder: folder, recursive: false)
        XCTAssertEqual(changed, ["/Users/me/Pictures/Inspo/shot.png"])
    }

    func testDropsPathsOutsideFolder() {
        let changed = FolderEventFilter.mediaChanges(
            paths: ["/Users/me/Pictures/Other/shot.png",
                    "/Users/me/Pictures/Inspo.png"],   // sibling, not a child
            folder: folder, recursive: false)
        XCTAssertTrue(changed.isEmpty)
    }

    func testDropsSidecarAndHiddenFiles() {
        let changed = FolderEventFilter.mediaChanges(
            paths: ["/Users/me/Pictures/Inspo/.muse/abc123.json",  // sidecar dir
                    "/Users/me/Pictures/Inspo/.DS_Store"],         // hidden file
            folder: folder, recursive: false)
        XCTAssertTrue(changed.isEmpty)
    }

    func testDropsNonViewableKinds() {
        let changed = FolderEventFilter.mediaChanges(
            paths: ["/Users/me/Pictures/Inspo/notes.xyzzy"],   // unknown → no viewer
            folder: folder, recursive: false)
        XCTAssertTrue(changed.isEmpty)
    }

    func testNonRecursiveDropsSubfolderFiles() {
        let changed = FolderEventFilter.mediaChanges(
            paths: ["/Users/me/Pictures/Inspo/sub/deep.png"],
            folder: folder, recursive: false)
        XCTAssertTrue(changed.isEmpty)
    }

    func testRecursiveKeepsSubfolderFilesButStillDropsSidecars() {
        let changed = FolderEventFilter.mediaChanges(
            paths: ["/Users/me/Pictures/Inspo/sub/deep.png",
                    "/Users/me/Pictures/Inspo/sub/.muse/x.json"],
            folder: folder, recursive: true)
        XCTAssertEqual(changed, ["/Users/me/Pictures/Inspo/sub/deep.png"])
    }

    func testDeduplicatesRepeatedPaths() {
        let changed = FolderEventFilter.mediaChanges(
            paths: ["/Users/me/Pictures/Inspo/a.jpg",
                    "/Users/me/Pictures/Inspo/a.jpg",
                    "/Users/me/Pictures/Inspo/b.jpg"],
            folder: folder, recursive: false)
        XCTAssertEqual(changed, ["/Users/me/Pictures/Inspo/a.jpg",
                                 "/Users/me/Pictures/Inspo/b.jpg"])
    }
}
