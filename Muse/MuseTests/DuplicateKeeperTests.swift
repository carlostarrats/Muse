//
//  DuplicateKeeperTests.swift
//  MuseTests
//
//  `DuplicateFinder.keeperIndex` is the one rule all three clusterers pick a
//  keeper with. It must be TOTAL (every non-empty group gets a keeper — the
//  old "no confident signal → no suggestion" left the review modal showing
//  KEEP on every tile with nothing pre-marked) and deterministic.
//

import XCTest
@testable import Muse

final class DuplicateKeeperTests: XCTestCase {

    private func c(_ path: String, pixels: Int = 0, bytes: Int64 = 0,
                   created: Int64? = nil) -> DuplicateFinder.KeeperCandidate {
        DuplicateFinder.KeeperCandidate(path: path, pixels: pixels,
                                        sizeBytes: bytes, createdAt: created)
    }

    func testEmptyGroupHasNoKeeper() {
        XCTAssertNil(DuplicateFinder.keeperIndex([]))
    }

    func testEveryNonEmptyGroupGetsExactlyOneKeeper() {
        // The regression that motivated this: same dimensions, near-identical
        // size, same basename in two folders — previously no suggestion at all.
        let idx = DuplicateFinder.keeperIndex([
            c("/a/photo.jpg", pixels: 1200 * 849, bytes: 202_000),
            c("/b/photo.jpg", pixels: 1200 * 849, bytes: 199_000)
        ])
        XCTAssertEqual(idx, 0, "at equal resolution the larger file is kept")
    }

    func testResolutionBeatsSize() {
        let idx = DuplicateFinder.keeperIndex([
            c("/a.jpg", pixels: 100, bytes: 9_000_000),
            c("/b.jpg", pixels: 400, bytes: 10)
        ])
        XCTAssertEqual(idx, 1, "never throw away resolution to keep bytes")
    }

    func testUnknownDimensionsFallThroughToBytes() {
        // The filename clusterer reads no dimensions: pixels is 0 for both.
        let idx = DuplicateFinder.keeperIndex([
            c("/a/photo.jpg", bytes: 100),
            c("/b/photo.jpg", bytes: 500)
        ])
        XCTAssertEqual(idx, 1)
    }

    func testPathQualityBreaksAFullTie() {
        // Byte-exact copies: pixels and size are identical by definition.
        let idx = DuplicateFinder.keeperIndex([
            c("/Users/me/Downloads/photo copy.jpg", pixels: 100, bytes: 100),
            c("/Users/me/Pictures/photo.jpg", pixels: 100, bytes: 100)
        ])
        XCTAssertEqual(idx, 1, "a clean name outside Downloads wins")
    }

    func testTrashIsNeverTheKeeper() {
        let idx = DuplicateFinder.keeperIndex([
            c("/Users/me/.Trash/photo.jpg", pixels: 100, bytes: 100),
            c("/Users/me/Pictures/some/deep/folder/photo.jpg", pixels: 100, bytes: 100)
        ])
        XCTAssertEqual(idx, 1)
    }

    func testOlderCopyWinsAnOtherwiseEqualTie() {
        let idx = DuplicateFinder.keeperIndex([
            c("/a/photo.jpg", pixels: 100, bytes: 100, created: 2_000_000_000),
            c("/a/photob.jpg", pixels: 100, bytes: 100, created: 1_000_000_000)
        ])
        XCTAssertEqual(idx, 1, "the older file is usually the original")
    }

    func testDeterministicRegardlessOfInputOrder() {
        let a = c("/a/photo.jpg", pixels: 100, bytes: 100)
        let b = c("/b/photo.jpg", pixels: 100, bytes: 100)
        XCTAssertEqual(DuplicateFinder.keeperIndex([a, b]).map { [a, b][$0].path },
                       DuplicateFinder.keeperIndex([b, a]).map { [b, a][$0].path },
                       "the same group must pick the same file across scans")
    }

    /// The seam that matters end to end: a keyed group seeds every non-keeper,
    /// so the modal opens with exactly one KEEP.
    func testSeedMarksEveryNonKeeper() {
        let urls = [URL(fileURLWithPath: "/a/photo.jpg"),
                    URL(fileURLWithPath: "/b/photo.jpg")]
        let seeded = DuplicateDeleteRules.seed(members: [
            (url: urls[0], isSuggestedKeeper: true),
            (url: urls[1], isSuggestedKeeper: false)
        ])
        XCTAssertEqual(seeded, [urls[1]])
    }
}
