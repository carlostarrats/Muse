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

    /// A locked aspect is honoured on every drag.
    func testAspectLockIsPreserved() {
        let r = CropDragMath.resize(full, handle: .bottomRight,
                                    by: CGSize(width: -0.4, height: 0), aspect: 1.0)
        XCTAssertEqual(r.w, r.h, accuracy: 1e-6)
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
