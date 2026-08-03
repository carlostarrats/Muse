//
//  ThumbnailCacheFormatResetTests.swift
//  MuseTests
//
//  THE BUG (2026-08-03, found in the running app): bumping the cache key to
//  force HDR-aware regeneration left every old-format thumbnail on disk as
//  unreachable garbage. Measured on the owner's library — 11,794 of 11,833
//  files were dead v1 keys occupying the FULL 2 GB cap, so the ~3,655 tiles
//  that now had to regenerate had no room. The grid came up empty.
//
//  A key change is not a migration. Changing the key orphans the old data;
//  something has to delete it.
//

import XCTest
@testable import Muse

final class ThumbnailCacheFormatResetTests: XCTestCase {

    func testAStaleMarkerRequestsAReset() {
        XCTAssertTrue(ThumbnailCache.needsFormatReset(marker: "1"))
        XCTAssertTrue(ThumbnailCache.needsFormatReset(marker: "0"))
    }

    /// A cache directory that predates the marker entirely — every existing
    /// library on the day this ships.
    func testAMissingMarkerRequestsAReset() {
        XCTAssertTrue(ThumbnailCache.needsFormatReset(marker: nil))
    }

    func testTheCurrentMarkerDoesNotResetEveryLaunch() {
        XCTAssertFalse(
            ThumbnailCache.needsFormatReset(marker: ThumbnailCache.cacheFormatMarker))
    }

    /// The reset must actually reclaim the space, and must leave the marker
    /// behind so the next launch is a no-op.
    func testResetRemovesStaleEntriesAndWritesTheMarker() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<5 {
            try Data("stale".utf8).write(to: dir.appendingPathComponent("\(i).png"))
        }
        try Data("stale".utf8).write(to: dir.appendingPathComponent("x.heic"))

        ThumbnailCache.resetCacheFormatIfNeeded(in: dir)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(remaining.filter { $0.hasSuffix(".png") || $0.hasSuffix(".heic") }, [],
                       "the stale thumbnails must be gone, not merely unreachable")
        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent(ThumbnailCache.formatMarkerName),
                       encoding: .utf8),
            ThumbnailCache.cacheFormatMarker)
    }

    /// Second call is a no-op — it must not wipe a warm cache on every launch.
    func testResetIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ThumbnailCache.resetCacheFormatIfNeeded(in: dir)

        let keeper = dir.appendingPathComponent("keep.png")
        try Data("warm".utf8).write(to: keeper)
        ThumbnailCache.resetCacheFormatIfNeeded(in: dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path),
                      "a second launch must not wipe the cache it just rebuilt")
    }
}
