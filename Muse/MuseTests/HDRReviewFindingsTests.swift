//
//  HDRReviewFindingsTests.swift
//  MuseTests
//
//  Self-review of the HDR work's own diff (2026-08-03). Every test here is a
//  defect the review found in code that was already committed, green, and
//  running — which is the argument for reviewing your own diff as a separate
//  pass rather than trusting the one that wrote it.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

final class HDRReviewFindingsTests: XCTestCase {

    // MARK: - F1: the format reset must not block launch

    /// THE BUG: the reset deleted every stale entry INLINE, from
    /// `ThumbnailCache.init` — and that type is `@MainActor`. On the measured
    /// library that is one directory scan plus 11,794 `removeItem` calls on the
    /// main thread during launch. Staging by RENAME is O(1); the deletion then
    /// happens off the main thread.
    func testResetStagesByRenameRatherThanDeletingInline() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reset-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<20 {
            try Data("stale".utf8).write(to: dir.appendingPathComponent("\(i).png"))
        }

        let staged = ThumbnailCache.resetCacheFormatIfNeeded(in: dir)

        let stagedURL = try XCTUnwrap(staged, "a stale cache must be staged for deletion")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path),
                      "the old entries must still exist under the staged name")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(remaining.filter { $0.hasSuffix(".png") }, [],
                       "the live cache directory must be empty immediately")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(ThumbnailCache.formatMarkerName).path))
    }

    func testResetReturnsNilWhenThereIsNothingToReclaim() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reset-noop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = ThumbnailCache.resetCacheFormatIfNeeded(in: dir)
        XCTAssertNil(ThumbnailCache.resetCacheFormatIfNeeded(in: dir),
                     "an already-current cache must not be staged again")
    }

    // MARK: - F7: a staged cache orphaned by a crash must be reclaimed

    /// THE BUG (round 2): the reset renames the cache aside and deletes it in
    /// the background. Quit or crash in between and that directory survives —
    /// and `enforceDiskCap` cannot reclaim it, because the cap only looks
    /// INSIDE the cache root and this is a sibling. On the measured library
    /// that is 2 GB stranded outside anything that counts it.
    func testStagedCachesAreSweptOnLaunch() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-\(UUID().uuidString)")
        let root = parent.appendingPathComponent("ThumbnailCache")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let orphans = (0..<2).map {
            parent.appendingPathComponent("ThumbnailCache-stale-orphan\($0)")
        }
        for orphan in orphans {
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
            try Data("leaked".utf8).write(to: orphan.appendingPathComponent("a.png"))
        }

        // Compared by PATH, not by URL: `appendingPathComponent` stats the
        // filesystem and adds a trailing slash for a directory that exists, so
        // two URLs naming the same directory are not `==`.
        XCTAssertEqual(
            Set(ThumbnailCache.stagedCacheURLs(besideRoot: root).map { $0.standardizedFileURL.path }),
            Set(orphans.map { $0.standardizedFileURL.path }))
        ThumbnailCache.sweepStagedCaches(besideRoot: root)

        for orphan in orphans {
            XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path),
                      "the live cache must survive the sweep")
    }

    /// The sweep must not reach anything that merely lives nearby.
    func testSweepIgnoresUnrelatedNeighbours() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-scope-\(UUID().uuidString)")
        let root = parent.appendingPathComponent("ThumbnailCache")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bystander = parent.appendingPathComponent("muse.sqlite")
        try Data("precious".utf8).write(to: bystander)

        XCTAssertEqual(ThumbnailCache.stagedCacheURLs(besideRoot: root).map(\.path), [])
        ThumbnailCache.sweepStagedCaches(besideRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bystander.path))
    }

    // MARK: - F4: a failed HEIC write must not poison the cache forever

    /// THE BUG (disk-full lens, from the unrun list in REVIEW-LENSES): the HEIC
    /// writer was `try?` and returned silently. A write that fails leaves NO
    /// cache file, so that tile re-decodes from scratch on every launch,
    /// forever, with nothing anywhere saying why. The writer now reports
    /// whether it produced a file so the caller can fall back to PNG — a flat
    /// thumbnail beats an infinite decode loop.
    func testHEICWriterReportsFailure() {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        let unwritable = URL(fileURLWithPath: "/System/definitely-not-writable/x.heic")
        XCTAssertFalse(ThumbnailCache.writeHEIC(image, to: unwritable))
    }

    func testHEICWriterReportsSuccess() throws {
        let source = try HDRTestFixtures.hdrHEIC(value: 4.0)
        let cg = try XCTUnwrap(HDRDecode.decode(url: source, maxPixel: 0))
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ok-\(UUID().uuidString).heic")
        XCTAssertTrue(ThumbnailCache.writeHEIC(image, to: out))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: - F6: the full-resolution decode must honour EXIF orientation

    /// THE BUG: `decode(maxPixel: 0)` goes through
    /// `CGImageSourceCreateImageAtIndex`, which IGNORES
    /// `kCGImageSourceCreateThumbnailWithTransform` — that key only applies to
    /// the thumbnail API. Measured on a 40×20 file tagged orientation 6: the
    /// thumbnail path returned 20×40 (correct) while the full path returned
    /// 40×20 (sideways). Same function, two different contracts depending on an
    /// argument — a landmine for the first full-resolution caller.
    func testFullResolutionDecodeIsOrientedLikeTheThumbnailPath() throws {
        let url = try Self.orientedFixture()
        let full = try XCTUnwrap(HDRDecode.decode(url: url, maxPixel: 0))
        let thumb = try XCTUnwrap(HDRDecode.decode(url: url, maxPixel: 40))
        XCTAssertEqual(full.width, 20, "a 40×20 file tagged orientation 6 displays as 20×40")
        XCTAssertEqual(full.height, 40)
        XCTAssertEqual(full.width > full.height, thumb.width > thumb.height,
                       "both rungs must agree on which way up the photo is")
    }

    /// 40×20 landscape tagged orientation 6, so a correct decode is 20×40.
    private static func orientedFixture() throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let cg = try XCTUnwrap(ctx.makeImage())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriented-\(UUID().uuidString).heic")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType("public.heic")!.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }
}
