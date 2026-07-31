import XCTest
@testable import Muse

/// `appliedDisplaySize` is what `EffectiveDimensions` hands to the grid, the
/// hero flight and the Info card — a wrong answer here shows up as tiles
/// packing at the wrong aspect and the hero flight taking off from a wrong
/// rect, not as anything that looks like a geometry bug.
final class GeometryParamsTests: XCTestCase {
    func testNoOpAtIdentity() {
        XCTAssertEqual(GeometryParams.neutral.appliedDisplaySize(to: CGSize(width: 100, height: 50)),
                       CGSize(width: 100, height: 50))
    }

    func testQuarterTurnsSwapDimensions() {
        var g = GeometryParams.neutral; g.quarterTurns = 1
        XCTAssertEqual(g.appliedDisplaySize(to: CGSize(width: 100, height: 50)),
                       CGSize(width: 50, height: 100))
    }

    func testTwoQuarterTurnsKeepDimensions() {
        var g = GeometryParams.neutral; g.quarterTurns = 2
        XCTAssertEqual(g.appliedDisplaySize(to: CGSize(width: 100, height: 50)),
                       CGSize(width: 100, height: 50))
    }

    func testNegativeQuarterTurnsNormalize() {
        var g = GeometryParams.neutral; g.quarterTurns = -1
        XCTAssertEqual(g.appliedDisplaySize(to: CGSize(width: 100, height: 50)),
                       CGSize(width: 50, height: 100))
    }

    func testCropAppliesUnitRectToSize() {
        var g = GeometryParams.neutral
        g.crop = CropRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5)
        XCTAssertEqual(g.appliedDisplaySize(to: CGSize(width: 200, height: 200)),
                       CGSize(width: 100, height: 100))
    }

    func testFullCropIsANoOp() {
        var g = GeometryParams.neutral; g.crop = .full
        XCTAssertEqual(g.appliedDisplaySize(to: CGSize(width: 80, height: 40)),
                       CGSize(width: 80, height: 40))
        XCTAssertTrue(g.isNeutral)
    }

    func testCropThenRotateOrdersCorrectly() {
        var g = GeometryParams.neutral
        g.crop = CropRect(x: 0, y: 0, w: 0.5, h: 1)
        g.quarterTurns = 1
        // 200x100 → crop to 100x100 → rotate → 100x100
        XCTAssertEqual(g.appliedDisplaySize(to: CGSize(width: 200, height: 100)),
                       CGSize(width: 100, height: 100))
    }

    func testFlipsDoNotChangeSize() {
        var g = GeometryParams.neutral; g.flipH = true; g.flipV = true
        XCTAssertEqual(g.appliedDisplaySize(to: CGSize(width: 80, height: 40)),
                       CGSize(width: 80, height: 40))
        XCTAssertFalse(g.isNeutral)
    }

    func testStraightenAloneIsNotNeutral() {
        var g = GeometryParams.neutral; g.straightenDegrees = 2
        XCTAssertFalse(g.isNeutral)
    }

    func testClampedBoundsStraightenAndTurns() {
        var g = GeometryParams.neutral
        g.straightenDegrees = 900
        g.quarterTurns = 7
        let c = g.clamped()
        XCTAssertEqual(c.straightenDegrees, 45)
        XCTAssertEqual(c.quarterTurns, 3)
    }
}
