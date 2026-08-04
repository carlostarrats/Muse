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

    // MARK: - The crop is clamped too
    //
    // Every other parameter on a stack passes through `clamped()` before it
    // reaches the renderer; the crop used to be forwarded untouched on the
    // assumption that `CropDragMath` wrote it. A stack also arrives decoded
    // from a `.muselibrary` preset and from a sidecar, where nothing enforces
    // that. A zero-or-negative extent survives into
    // `EditRenderer.applyGeometry`, where `cropped(to:)` yields an EMPTY extent
    // — the photo renders as nothing.

    /// The load-bearing half: a legitimate crop must come back BYTE-IDENTICAL,
    /// or every edited thumbnail in every library re-keys on its `stack_hash`.
    func testLegitimateCropIsUnchanged() {
        let crop = CropRect(x: 0.1, y: 0.2, w: 0.5, h: 0.6)
        XCTAssertEqual(crop.clampedToUnitSquare(), crop)
        var g = GeometryParams.neutral
        g.crop = crop
        XCTAssertEqual(g.clamped().crop, crop)
    }

    func testFullCropIsUnchanged() {
        XCTAssertEqual(CropRect.full.clampedToUnitSquare(), CropRect.full)
    }

    func testZeroExtentCropBecomesNil() {
        XCTAssertNil(CropRect(x: 0.2, y: 0.2, w: 0, h: 0.5).clampedToUnitSquare())
        XCTAssertNil(CropRect(x: 0.2, y: 0.2, w: 0.5, h: 0).clampedToUnitSquare())
    }

    func testNegativeExtentCropBecomesNil() {
        XCTAssertNil(CropRect(x: 0.5, y: 0.5, w: -0.4, h: 0.3).clampedToUnitSquare())
    }

    /// A rect that starts inside but runs off the edge is trimmed to the
    /// square rather than dropped — it still describes a real region.
    func testOverhangingCropIsTrimmedNotDropped() {
        let c = CropRect(x: 0.75, y: 0.5, w: 0.9, h: 0.9).clampedToUnitSquare()
        XCTAssertEqual(c?.x ?? -1, 0.75, accuracy: 1e-12)
        XCTAssertEqual(c?.w ?? -1, 0.25, accuracy: 1e-12)
        XCTAssertEqual(c?.h ?? -1, 0.5, accuracy: 1e-12)
    }

    /// Origin past the far edge: clamping x to 1 leaves no width, so there is
    /// nothing to crop to.
    func testCropOriginPastTheFarEdgeBecomesNil() {
        XCTAssertNil(CropRect(x: 4, y: 0, w: 1, h: 1).clampedToUnitSquare())
        XCTAssertNil(CropRect(x: 0, y: 4, w: 1, h: 1).clampedToUnitSquare())
    }

    /// A rect that starts BEFORE the origin and covers the whole square trims
    /// to the full square — it still describes "all of it", which is a real
    /// (if redundant) crop, not a degenerate one.
    func testCropStartingBeforeTheOriginTrimsToFull() {
        XCTAssertEqual(CropRect(x: -3, y: -3, w: 1, h: 1).clampedToUnitSquare(),
                       CropRect.full)
    }

    /// `min`/`max` PROPAGATE NaN rather than clamping it, so a non-finite value
    /// would otherwise pass through wearing a clamp's name.
    func testNonFiniteCropBecomesNil() {
        XCTAssertNil(CropRect(x: .nan, y: 0, w: 1, h: 1).clampedToUnitSquare())
        XCTAssertNil(CropRect(x: 0, y: 0, w: .nan, h: 1).clampedToUnitSquare())
        XCTAssertNil(CropRect(x: 0, y: 0, w: 1, h: .infinity).clampedToUnitSquare())
    }

    /// The consequence the clamp exists to prevent, stated in the units the
    /// grid and the hero flight actually consume.
    func testDegenerateCropNoLongerProducesAZeroDisplaySize() {
        var g = GeometryParams.neutral
        g.crop = CropRect(x: 0, y: 0, w: 0, h: 1)
        let size = g.clamped().appliedDisplaySize(to: CGSize(width: 100, height: 50))
        XCTAssertEqual(size, CGSize(width: 100, height: 50))
    }
}
