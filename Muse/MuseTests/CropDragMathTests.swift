//
//  CropDragMathTests.swift
//  MuseTests
//
//  Pure crop geometry. Every rect is normalized to the image with a TOP-LEFT
//  origin and y down — the same convention `CropRect` and
//  `EditRenderer.applyGeometry` use, so a value from here goes into
//  `GeometryParams.crop` with no flip.
//

import XCTest
@testable import Muse

final class CropDragMathTests: XCTestCase {

    private let full = CropRect(x: 0, y: 0, w: 1, h: 1)

    // MARK: - Dragging

    func testDraggingBottomRightInwardShrinksTheRect() {
        let r = CropDragMath.resize(full, handle: .bottomRight,
                                    by: CGSize(width: -0.2, height: -0.3), aspect: nil)
        XCTAssertEqual(r.x, 0, accuracy: 1e-9)
        XCTAssertEqual(r.y, 0, accuracy: 1e-9)
        XCTAssertEqual(r.w, 0.8, accuracy: 1e-9)
        XCTAssertEqual(r.h, 0.7, accuracy: 1e-9)
    }

    func testDraggingTopLeftMovesTheOriginAndShrinks() {
        let r = CropDragMath.resize(full, handle: .topLeft,
                                    by: CGSize(width: 0.25, height: 0.1), aspect: nil)
        XCTAssertEqual(r.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(r.y, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r.w, 0.75, accuracy: 1e-9)
        XCTAssertEqual(r.h, 0.9, accuracy: 1e-9)
    }

    /// A mid-edge handle moves ONE edge. Dragging the right bar must not move
    /// the top or bottom.
    func testMidEdgeHandleMovesOnlyItsOwnEdge() {
        let r = CropDragMath.resize(full, handle: .right,
                                    by: CGSize(width: -0.3, height: 0.5), aspect: nil)
        XCTAssertEqual(r.y, 0, accuracy: 1e-9)
        XCTAssertEqual(r.h, 1, accuracy: 1e-9)
        XCTAssertEqual(r.w, 0.7, accuracy: 1e-9)
    }

    /// The frame can never invert by dragging past the opposite edge.
    func testCannotDragPastTheOppositeEdge() {
        let r = CropDragMath.resize(full, handle: .bottomRight,
                                    by: CGSize(width: -5, height: -5), aspect: nil)
        XCTAssertEqual(r.w, CropDragMath.minimumSide, accuracy: 1e-9)
        XCTAssertEqual(r.h, CropDragMath.minimumSide, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(r.x, -1e-9)
        XCTAssertLessThanOrEqual(r.x + r.w, 1 + 1e-9)
    }

    /// Nor leave the image.
    func testCannotDragOutsideTheImage() {
        let r = CropDragMath.resize(full, handle: .topLeft,
                                    by: CGSize(width: -0.5, height: -0.5), aspect: nil)
        XCTAssertEqual(r.x, 0, accuracy: 1e-9)
        XCTAssertEqual(r.y, 0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(r.x + r.w, 1 + 1e-9)
        XCTAssertLessThanOrEqual(r.y + r.h, 1 + 1e-9)
    }

    /// Whatever the drag, the result is always a valid sub-rect of the image.
    func testEveryHandleAndDragProducesAValidRect() {
        for handle in CropDragMath.Handle.allCases {
            for dx in stride(from: -1.2, through: 1.2, by: 0.3) {
                for dy in stride(from: -1.2, through: 1.2, by: 0.3) {
                    let r = CropDragMath.resize(full, handle: handle,
                                                by: CGSize(width: dx, height: dy),
                                                aspect: nil)
                    XCTAssertGreaterThanOrEqual(r.x, -1e-9, "\(handle) \(dx),\(dy)")
                    XCTAssertGreaterThanOrEqual(r.y, -1e-9, "\(handle) \(dx),\(dy)")
                    XCTAssertGreaterThanOrEqual(r.w, CropDragMath.minimumSide - 1e-9)
                    XCTAssertGreaterThanOrEqual(r.h, CropDragMath.minimumSide - 1e-9)
                    XCTAssertLessThanOrEqual(r.x + r.w, 1 + 1e-9, "\(handle) \(dx),\(dy)")
                    XCTAssertLessThanOrEqual(r.y + r.h, 1 + 1e-9, "\(handle) \(dx),\(dy)")
                }
            }
        }
    }

    /// A locked aspect is honoured on every drag — measured in PIXELS.
    ///
    /// The previous version of this test asserted `r.w == r.h` for a 1:1 lock,
    /// which is the bug restated rather than a test of it: a `CropRect`'s w and
    /// h are fractions of the image's width and height, so equal normalized
    /// sides on a 3:2 photo are a 1.5:1 rectangle. Every assertion here
    /// converts back to pixels before checking.
    func testAspectLockIsPreservedInPixels() {
        for imageAspect in [1.0, 1.5, 0.75, 2.0] {
            for target in [1.0, 4.0 / 5.0, 16.0 / 9.0, 3.0 / 2.0] {
                let r = CropDragMath.resize(full, handle: .bottomRight,
                                            by: CGSize(width: -0.4, height: -0.1),
                                            aspect: target, imageAspect: imageAspect)
                let pixelAspect = (r.w * imageAspect) / r.h
                XCTAssertEqual(pixelAspect, target, accuracy: 1e-6,
                               "image \(imageAspect), target \(target)")
            }
        }
    }

    /// The concrete case that shipped broken: a 1:1 lock on a 3:2 photo.
    func testSquareLockOnALandscapePhotoIsActuallySquare() {
        let r = CropDragMath.resize(full, handle: .bottomRight,
                                    by: CGSize(width: -0.3, height: -0.3),
                                    aspect: 1.0, imageAspect: 1.5)
        XCTAssertEqual((r.w * 1.5) / r.h, 1.0, accuracy: 1e-6)
        XCTAssertNotEqual(r.w, r.h, accuracy: 1e-6,
                          "a square on a 3:2 photo must NOT have equal normalized sides")
    }

    /// A locked drag still cannot leave the image or invert.
    func testAspectLockedDragStaysInsideTheImage() {
        for handle in CropDragMath.Handle.allCases {
            for d in stride(from: -1.0, through: 1.0, by: 0.25) {
                let r = CropDragMath.resize(full, handle: handle,
                                            by: CGSize(width: d, height: d),
                                            aspect: 16.0 / 9.0, imageAspect: 1.5)
                XCTAssertGreaterThanOrEqual(r.x, -1e-9, "\(handle) \(d)")
                XCTAssertGreaterThanOrEqual(r.y, -1e-9, "\(handle) \(d)")
                XCTAssertLessThanOrEqual(r.x + r.w, 1 + 1e-9, "\(handle) \(d)")
                XCTAssertLessThanOrEqual(r.y + r.h, 1 + 1e-9, "\(handle) \(d)")
            }
        }
    }

    /// The minimum-side floor holds even when the lock and the image fight —
    /// every other caller relies on it, so it wins over the ratio.
    func testMinimumSideHoldsEvenUnderAnExtremeLock() {
        for imageAspect in [0.05, 0.2, 1.0, 5.0, 20.0] {
            for target in [1.0 / 20.0, 0.5, 1.0, 20.0] {
                for handle in CropDragMath.Handle.allCases {
                    let r = CropDragMath.resize(full, handle: handle,
                                                by: CGSize(width: -0.9, height: -0.9),
                                                aspect: target, imageAspect: imageAspect)
                    XCTAssertGreaterThanOrEqual(r.w, CropDragMath.minimumSide - 1e-9,
                                                "img \(imageAspect) target \(target)")
                    XCTAssertGreaterThanOrEqual(r.h, CropDragMath.minimumSide - 1e-9,
                                                "img \(imageAspect) target \(target)")
                    XCTAssertLessThanOrEqual(r.x + r.w, 1 + 1e-9)
                    XCTAssertLessThanOrEqual(r.y + r.h, 1 + 1e-9)
                }
            }
        }
    }

    /// `fit` and a locked drag must agree — picking "Square" and then nudging a
    /// handle must not silently change the shape.
    func testFitAndLockedDragAgreeOnShape() {
        let imageAspect = 1.5
        let fitted = CropDragMath.fit(aspect: 1.0, into: imageAspect)
        XCTAssertEqual((fitted.w * imageAspect) / fitted.h, 1.0, accuracy: 1e-6)

        let dragged = CropDragMath.resize(fitted, handle: .bottomRight,
                                          by: CGSize(width: -0.1, height: 0),
                                          aspect: 1.0, imageAspect: imageAspect)
        XCTAssertEqual((dragged.w * imageAspect) / dragged.h, 1.0, accuracy: 1e-6)
    }

    // MARK: - Display space vs source space

    /// With no rotation and no flips the two spaces are the same.
    func testIdentityGeometryLeavesTheRectAlone() {
        let r = CropRect(x: 0.2, y: 0.1, w: 0.5, h: 0.4)
        XCTAssertEqual(CropDragMath.sourceRect(fromDisplay: r, quarterTurns: 0,
                                               flipH: false, flipV: false), r)
        XCTAssertEqual(CropDragMath.displayRect(fromSource: r, quarterTurns: 0,
                                                flipH: false, flipV: false), r)
    }

    /// THE BUG: crop the top band of a photo rotated 90° clockwise, and the
    /// stored rect must be the LEFT band of the source — because
    /// `applyGeometry` crops before it turns.
    func testTopOfAClockwiseRotatedDisplayIsTheLeftOfTheSource() {
        let topBand = CropRect(x: 0, y: 0, w: 1, h: 0.5)
        let source = CropDragMath.sourceRect(fromDisplay: topBand, quarterTurns: 1,
                                             flipH: false, flipV: false)
        XCTAssertEqual(source.x, 0, accuracy: 1e-9)
        XCTAssertEqual(source.y, 0, accuracy: 1e-9)
        XCTAssertEqual(source.w, 0.5, accuracy: 1e-9)
        XCTAssertEqual(source.h, 1, accuracy: 1e-9)
    }

    /// Round-trip through every orientation the model can express.
    func testDisplayAndSourceRoundTripForEveryOrientation() {
        let rects = [CropRect(x: 0, y: 0, w: 1, h: 1),
                     CropRect(x: 0.1, y: 0.2, w: 0.5, h: 0.3),
                     CropRect(x: 0.45, y: 0.05, w: 0.5, h: 0.9)]
        for r in rects {
            for turns in 0..<4 {
                for fh in [false, true] {
                    for fv in [false, true] {
                        let source = CropDragMath.sourceRect(fromDisplay: r,
                                                             quarterTurns: turns,
                                                             flipH: fh, flipV: fv)
                        let back = CropDragMath.displayRect(fromSource: source,
                                                            quarterTurns: turns,
                                                            flipH: fh, flipV: fv)
                        XCTAssertEqual(back.x, r.x, accuracy: 1e-9, "t\(turns) h\(fh) v\(fv)")
                        XCTAssertEqual(back.y, r.y, accuracy: 1e-9, "t\(turns) h\(fh) v\(fv)")
                        XCTAssertEqual(back.w, r.w, accuracy: 1e-9, "t\(turns) h\(fh) v\(fv)")
                        XCTAssertEqual(back.h, r.h, accuracy: 1e-9, "t\(turns) h\(fh) v\(fv)")
                    }
                }
            }
        }
    }

    /// A mapped rect is still a valid sub-rect — it never leaves the unit square.
    func testMappedRectsStayInsideTheUnitSquare() {
        let r = CropRect(x: 0.3, y: 0.05, w: 0.6, h: 0.7)
        for turns in -4...7 {
            for fh in [false, true] {
                for fv in [false, true] {
                    let s = CropDragMath.sourceRect(fromDisplay: r, quarterTurns: turns,
                                                    flipH: fh, flipV: fv)
                    XCTAssertGreaterThanOrEqual(s.x, -1e-9)
                    XCTAssertGreaterThanOrEqual(s.y, -1e-9)
                    XCTAssertLessThanOrEqual(s.x + s.w, 1 + 1e-9)
                    XCTAssertLessThanOrEqual(s.y + s.h, 1 + 1e-9)
                }
            }
        }
    }

    /// Full frame maps to full frame in every orientation — rotating a photo
    /// must never introduce a crop.
    func testFullFrameSurvivesEveryOrientation() {
        for turns in 0..<4 {
            for fh in [false, true] {
                for fv in [false, true] {
                    let s = CropDragMath.sourceRect(fromDisplay: .full, quarterTurns: turns,
                                                    flipH: fh, flipV: fv)
                    XCTAssertTrue(s.isFull, "turns \(turns) h\(fh) v\(fv) -> \(s)")
                }
            }
        }
    }

    /// A quarter turn transposes the aspect the user is looking at.
    func testDisplayAspectTransposesOnOddTurns() {
        XCTAssertEqual(CropDragMath.displayAspect(source: 1.5, quarterTurns: 0),
                       1.5, accuracy: 1e-9)
        XCTAssertEqual(CropDragMath.displayAspect(source: 1.5, quarterTurns: 1),
                       1 / 1.5, accuracy: 1e-9)
        XCTAssertEqual(CropDragMath.displayAspect(source: 1.5, quarterTurns: 2),
                       1.5, accuracy: 1e-9)
        XCTAssertEqual(CropDragMath.displayAspect(source: 1.5, quarterTurns: 3),
                       1 / 1.5, accuracy: 1e-9)
        XCTAssertEqual(CropDragMath.displayAspect(source: 1.5, quarterTurns: -1),
                       1 / 1.5, accuracy: 1e-9)
    }

    // MARK: - Fitting a preset

    /// Fitting 1:1 into a 3:2 frame gives a centred square limited by height.
    func testFitSquareIntoLandscapeIsCentred() {
        let r = CropDragMath.fit(aspect: 1.0, into: 1.5)
        XCTAssertEqual(r.h, 1.0, accuracy: 1e-9)
        XCTAssertEqual(r.w, 1.0 / 1.5, accuracy: 1e-6)
        XCTAssertEqual(r.x, (1 - r.w) / 2, accuracy: 1e-6)
        XCTAssertEqual(r.y, 0, accuracy: 1e-6)
    }

    /// And the mirror: a wide target in a square frame is limited by width.
    func testFitWideIntoSquareIsCentred() {
        let r = CropDragMath.fit(aspect: 16.0 / 9.0, into: 1.0)
        XCTAssertEqual(r.w, 1.0, accuracy: 1e-9)
        XCTAssertEqual(r.h, 9.0 / 16.0, accuracy: 1e-6)
        XCTAssertEqual(r.y, (1 - r.h) / 2, accuracy: 1e-6)
    }

    /// Matching aspect fills the frame exactly — picking "3:2" on a 3:2 photo
    /// must not crop anything at all.
    func testFitMatchingAspectIsFullFrame() {
        let r = CropDragMath.fit(aspect: 1.5, into: 1.5)
        XCTAssertEqual(r.w, 1.0, accuracy: 1e-6)
        XCTAssertEqual(r.h, 1.0, accuracy: 1e-6)
    }

    // MARK: - Straighten auto-inset

    /// 0° must not crop at all — otherwise merely opening the card costs pixels.
    func testZeroStraightenLeavesFullFrame() {
        let r = CropDragMath.straightenInset(degrees: 0, aspect: 1.5)
        XCTAssertEqual(r.w, 1.0, accuracy: 1e-9)
        XCTAssertEqual(r.h, 1.0, accuracy: 1e-9)
    }

    /// A rotation insets enough that no corner leaves the source, and stays
    /// centred. This is what stops the transparent wedges.
    func testStraightenInsetsAndStaysCentred() {
        let r = CropDragMath.straightenInset(degrees: 10, aspect: 1.5)
        XCTAssertLessThan(r.w, 1.0)
        XCTAssertLessThan(r.h, 1.0)
        XCTAssertEqual(r.x, (1 - r.w) / 2, accuracy: 1e-6)
        XCTAssertEqual(r.y, (1 - r.h) / 2, accuracy: 1e-6)
    }

    /// Tilting left and right cost the same area.
    func testStraightenInsetIsSymmetric() {
        let a = CropDragMath.straightenInset(degrees: 12, aspect: 1.5)
        let b = CropDragMath.straightenInset(degrees: -12, aspect: 1.5)
        XCTAssertEqual(a.w, b.w, accuracy: 1e-9)
        XCTAssertEqual(a.h, b.h, accuracy: 1e-9)
    }

    /// More tilt costs more area, monotonically — a slider that sometimes gave
    /// back area as you pushed further would read as a bug.
    func testStraightenInsetIsMonotonic() {
        var previous = 1.0
        for degrees in stride(from: 0.0, through: 45.0, by: 5.0) {
            let r = CropDragMath.straightenInset(degrees: degrees, aspect: 1.5)
            XCTAssertLessThanOrEqual(r.w, previous + 1e-9, "at \(degrees)°")
            previous = r.w
        }
    }

    /// Whatever the angle or shape, the inset stays a valid sub-rect.
    func testStraightenInsetStaysInsideTheFrame() {
        for aspect in [0.5, 1.0, 1.5, 2.0] {
            for degrees in stride(from: -45.0, through: 45.0, by: 7.5) {
                let r = CropDragMath.straightenInset(degrees: degrees, aspect: aspect)
                XCTAssertGreaterThan(r.w, 0, "\(aspect) @ \(degrees)")
                XCTAssertGreaterThan(r.h, 0, "\(aspect) @ \(degrees)")
                XCTAssertLessThanOrEqual(r.x + r.w, 1 + 1e-9, "\(aspect) @ \(degrees)")
                XCTAssertLessThanOrEqual(r.y + r.h, 1 + 1e-9, "\(aspect) @ \(degrees)")
            }
        }
    }
}
