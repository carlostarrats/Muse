import XCTest
@testable import Muse

/// Empirical QA cross-check (feat/next-41): the sidebar's IMMEDIATE folder count
/// (`FolderStats.compute`) must equal the number of tiles the one-level grid
/// shows (`FolderReader.files(includeFolders: true)`) for the SAME directory —
/// including tricky entries (an .app package, a symlink-to-directory, a hidden
/// file). If these two enumerations ever diverge, the sidebar count would lie
/// about what the grid displays. Per-task reviews trace this in code; this
/// asserts it on a real temp directory.
final class FolderCountGridConsistencyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-count-consistency-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // 3 plain files
        for n in ["a.jpg", "b.pdf", "c.txt"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(n))
        }
        // 2 plain subfolders
        for f in ["Sub1", "Sub2"] {
            try fm.createDirectory(at: dir.appendingPathComponent(f),
                                   withIntermediateDirectories: true)
        }
        // 1 .app package (a directory with a bundle extension → treated as a file)
        let app = dir.appendingPathComponent("Thing.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents"),
                               withIntermediateDirectories: true)
        try Data("APPL????".utf8)
            .write(to: app.appendingPathComponent("Contents/PkgInfo"))
        // 1 symlink to a directory
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link-to-sub"),
                                  withDestinationURL: dir.appendingPathComponent("Sub1"))
        // 1 hidden file (must be excluded by BOTH when showHidden is false)
        try Data("h".utf8).write(to: dir.appendingPathComponent(".hidden"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSidebarCountEqualsGridTileCount() {
        let count = FolderStats.compute(folder: dir).immediateFileCount
        let tiles = FolderReader.files(in: dir, includeFolders: true).count
        XCTAssertEqual(count, tiles,
            "Sidebar immediate count (\(count)) must equal grid tile count (\(tiles))")
        // 3 files + 2 subfolders + 1 package + 1 symlink = 7 visible; hidden excluded.
        XCTAssertEqual(tiles, 7, "Expected 7 non-hidden immediate entries")
    }

    func testHiddenAlsoExcludedWithShowHiddenParity() {
        // When the grid is asked to include hidden, the dotfile appears as a tile;
        // FolderStats has no showHidden override in the folder-browse path, so this
        // test only documents the grid side's hidden handling for completeness.
        let visibleTiles = FolderReader.files(in: dir, includeFolders: true)
        XCTAssertFalse(visibleTiles.contains { $0.url.lastPathComponent == ".hidden" },
                       "Hidden dotfile must not appear as a tile by default")
    }
}
