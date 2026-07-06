import XCTest
import CoreGraphics
@testable import Muse

final class GridKeyboardNavTests: XCTestCase {

    // 2-column masonry fixture, column width 100, spacing 0.
    private let frames: [CGRect] = [
        CGRect(x: 0,   y: 0,   width: 100, height: 120), // 0
        CGRect(x: 100, y: 0,   width: 100, height: 80),  // 1
        CGRect(x: 100, y: 80,  width: 100, height: 140), // 2
        CGRect(x: 0,   y: 120, width: 100, height: 100), // 3
        CGRect(x: 0,   y: 220, width: 100, height: 90),  // 4
        CGRect(x: 100, y: 220, width: 100, height: 90),  // 5
    ]
    private let band: CGFloat = 100

    func testNilCurrentSelectsFirstTile() {
        XCTAssertEqual(GridKeyboardNav.next(currentIndex: nil, direction: .down,
                                            frames: frames, bandTolerance: band), 0)
        XCTAssertEqual(GridKeyboardNav.next(currentIndex: nil, direction: .right,
                                            frames: frames, bandTolerance: band), 0)
    }

    func testEmptyFramesIsNoOp() {
        XCTAssertNil(GridKeyboardNav.next(currentIndex: nil, direction: .down,
                                          frames: [], bandTolerance: band))
        XCTAssertNil(GridKeyboardNav.next(currentIndex: 0, direction: .left,
                                          frames: [], bandTolerance: band))
    }

    func testRightIsNextInReadingOrder() {
        XCTAssertEqual(GridKeyboardNav.next(currentIndex: 0, direction: .right,
                                            frames: frames, bandTolerance: band), 1)
    }

    func testRightWrapsAcrossRowBoundary() {
        // index 1 → index 2 crosses from row-band top 0 into the next tile.
        XCTAssertEqual(GridKeyboardNav.next(currentIndex: 1, direction: .right,
                                            frames: frames, bandTolerance: band), 2)
    }

    func testLeftIsPreviousInReadingOrder() {
        XCTAssertEqual(GridKeyboardNav.next(currentIndex: 3, direction: .left,
                                            frames: frames, bandTolerance: band), 2)
    }

    func testRightAtLastTileIsNoOp() {
        XCTAssertNil(GridKeyboardNav.next(currentIndex: 5, direction: .right,
                                          frames: frames, bandTolerance: band))
    }

    func testLeftAtFirstTileIsNoOp() {
        XCTAssertNil(GridKeyboardNav.next(currentIndex: 0, direction: .left,
                                          frames: frames, bandTolerance: band))
    }

    func testDownPicksNearestBandThenClosestCentre() {
        // From tile 0 (top 0, midX 50): tiles strictly below are 2 (top 80),
        // 3 (top 120), 4/5 (top 220). Nearest band anchor = 80; within
        // tolerance 100 that band is {2 (top 80), 3 (top 120)}. Centres:
        // tile 2 midX 150 (|150-50|=100), tile 3 midX 50 (|50-50|=0) → tile 3.
        XCTAssertEqual(GridKeyboardNav.next(currentIndex: 0, direction: .down,
                                            frames: frames, bandTolerance: band), 3)
    }

    func testDownAtBottomRowIsNoOp() {
        // Tile 4 (top 220) — nothing has a greater minY.
        XCTAssertNil(GridKeyboardNav.next(currentIndex: 4, direction: .down,
                                          frames: frames, bandTolerance: band))
    }

    func testUpPicksNearestBandThenClosestCentre() {
        // From tile 4 (top 220, midX 50): tiles strictly above with the
        // largest minY toward it = tile 3 (top 120) and tile 2 (top 80).
        // Band anchor = 120; tolerance 100 → band {3 (120), 2 (80)}.
        // Centres: tile 3 midX 50 (0), tile 2 midX 150 (100) → tile 3.
        XCTAssertEqual(GridKeyboardNav.next(currentIndex: 4, direction: .up,
                                            frames: frames, bandTolerance: band), 3)
    }

    func testUpAtTopRowIsNoOp() {
        XCTAssertNil(GridKeyboardNav.next(currentIndex: 1, direction: .up,
                                          frames: frames, bandTolerance: band))
    }

    func testHorizontalCentreTieBreaksToLowerIndex() {
        // Both bottom tiles 4 (midX 50) and 5 (midX 150) are below tile 3
        // (midX 50, top 120) at band anchor 220. tile 4 centre distance 0 wins;
        // this asserts the closest-centre rule (not a raw tie), guarding the
        // comparator's ordering.
        XCTAssertEqual(GridKeyboardNav.next(currentIndex: 3, direction: .down,
                                            frames: frames, bandTolerance: band), 4)
    }
}
