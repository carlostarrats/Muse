//
//  ThumbnailVariantTests.swift
//  MuseTests
//
//  `invalidate(_:)` drops cached thumbnails by ENUMERATING renderedVariants —
//  the cache key is path-based, so any variant missing from that list survives
//  an in-place edit and serves the OLD image forever (the on-disk PNG outlives
//  launches). Two call sites had drifted off the list: the Duplicates tile, and
//  the hero's undecodable-format fallback, whose size came from the viewport and
//  so was unenumerable by construction.
//

import XCTest
@testable import Muse

final class ThumbnailVariantTests: XCTestCase {

    private func lists(_ size: CGFloat, scale: CGFloat) -> Bool {
        ThumbnailCache.renderedVariants.contains {
            $0.size.width == size && $0.size.height == size && $0.scale == scale
        }
    }

    /// Every size any call site requests must be listed.
    func testEveryRequestedVariantIsEnumerated() {
        XCTAssertTrue(lists(320, scale: 2.0), "grid tile + hero quick thumbnail")
        XCTAssertTrue(lists(160, scale: 2.0), "small hero fallback")
        XCTAssertTrue(lists(ThumbnailCache.duplicateTileSize, scale: 2.0), "duplicates modal tile")
        for s in ThumbnailCache.heroFallbackSizes {
            XCTAssertTrue(lists(s, scale: 1.0), "hero fallback ladder step \(s)")
        }
    }

    /// The ladder must absorb any viewport-derived size into a listed step,
    /// including values above the top step (which clamp to it).
    func testHeroFallbackQuantizesToTheLadder() {
        for raw in stride(from: CGFloat(1), through: 6000, by: 137) {
            let q = ThumbnailCache.heroFallbackSize(forMaxDimension: raw)
            XCTAssertTrue(ThumbnailCache.heroFallbackSizes.contains(q),
                          "\(raw) quantized to \(q), which is not a ladder step")
            XCTAssertTrue(lists(q, scale: 1.0))
        }
    }

    /// It rounds UP so the fallback is never rendered smaller than asked for
    /// (except above the ceiling, where it clamps).
    func testHeroFallbackRoundsUpWithinTheLadder() {
        XCTAssertEqual(ThumbnailCache.heroFallbackSize(forMaxDimension: 1600), 1600)
        XCTAssertEqual(ThumbnailCache.heroFallbackSize(forMaxDimension: 1601), 2048)
        XCTAssertEqual(ThumbnailCache.heroFallbackSize(forMaxDimension: 4096), 4096)
        XCTAssertEqual(ThumbnailCache.heroFallbackSize(forMaxDimension: 99999), 4096)
    }
}
