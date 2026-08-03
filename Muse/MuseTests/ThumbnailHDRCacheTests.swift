//
//  ThumbnailHDRCacheTests.swift
//  MuseTests
//
//  The disk cache used to be PNG-only, which hard-clips. These pin the two
//  things that had to change: the container an HDR tile is stored in, and the
//  key version that stops an upgrading library from serving its old flat PNGs.
//

import XCTest
import AppKit
import CoreGraphics
import ImageIO
import CryptoKit
@testable import Muse

final class ThumbnailHDRCacheTests: XCTestCase {

    func testHDRSourceCachesAsHEIC() {
        XCTAssertEqual(ThumbnailCache.cacheFileExtension(isHDR: true), "heic")
    }

    func testSDRSourceCachesAsPNG() {
        XCTAssertEqual(ThumbnailCache.cacheFileExtension(isHDR: false), "png")
    }

    /// Reads and deletes probe this list. If a third container is ever added,
    /// it must land here too or `invalidate` will leave a live orphan that
    /// resurfaces the moment the file changes.
    func testBothContainersAreEnumerated() {
        XCTAssertEqual(Set(ThumbnailCache.cacheFileExtensions), ["heic", "png"])
    }

    /// The cache key must have MOVED from its pre-HDR value, or every existing
    /// library keeps serving 8-bit PNGs and the grid stays flat while the hero
    /// goes HDR — exactly the mismatch this work exists to remove.
    func testCacheKeyMovedFromThePreHDRFormat() {
        let url = URL(fileURLWithPath: "/tmp/example.heic")
        let key = ThumbnailCache.cacheKeyForTesting(url: url,
                                                    size: CGSize(width: 320, height: 320),
                                                    scale: 2.0)
        // The v1 key for this exact input, recorded so a future change to the
        // key format is a deliberate act rather than an accident.
        let preHDRKey = ThumbnailHDRCacheTests.sha256Hex(
            "/tmp/example.heic|320x320@2.0")
        XCTAssertNotEqual(key, preHDRKey)
    }

    func testCacheKeyIsStableAcrossCalls() {
        let url = URL(fileURLWithPath: "/tmp/example.heic")
        let size = CGSize(width: 320, height: 320)
        XCTAssertEqual(ThumbnailCache.cacheKeyForTesting(url: url, size: size, scale: 2.0),
                       ThumbnailCache.cacheKeyForTesting(url: url, size: size, scale: 2.0))
    }

    /// The HEIC writer must produce a file that reads back with headroom.
    /// Writing a container that silently flattens would leave the grid flat
    /// while every other layer was correct — the hardest kind of bug to see.
    func testWriteHEICRoundTripsHeadroom() throws {
        let source = try HDRTestFixtures.hdrHEIC(value: 4.0)
        let cg = try XCTUnwrap(HDRDecode.decode(url: source, maxPixel: 0))
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("tile-\(UUID().uuidString).heic")
        ThumbnailCache.writeHEIC(image, to: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path),
                      "the HEIC writer produced no file")
        let px = try HDRTestFixtures.firstPixel(ofFileAt: out)
        XCTAssertGreaterThan(px.r, 2.0, "the cached tile lost its headroom")
    }

    /// Reconstructs the OLD key format, so the test can assert the key MOVED
    /// without making `ThumbnailCache`'s hashing internals public.
    private static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
