//
//  SocialCropMathTests.swift
//  MuseTests
//

import XCTest
import CoreGraphics
@testable import Muse

final class SocialCropMathTests: XCTestCase {
    func testZoomOneCenteredIsMaximalAspectFillRect() {
        // 4000×3000 source, target 4:5 — the minimal crop that fills a 4:5
        // frame from a 4:3 source is width-constrained and centered.
        let rect = SocialCropMath.rect(sourceSize: CGSize(width: 4000, height: 3000),
                                       targetAspect: 4.0 / 5.0,
                                       zoom: 1, center: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(rect.width / rect.height, (4.0 / 5.0) * (3000.0 / 4000.0), accuracy: 0.0001)
        XCTAssertEqual(rect.height, 1, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertLessThanOrEqual(rect.maxX, 1)
        XCTAssertEqual(rect.midX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(rect.midY, 0.5, accuracy: 0.0001)
    }

    func testRectNeverExitsUnitSquareUnderExtremeCenters() {
        let source = CGSize(width: 4000, height: 3000)
        for center in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1),
                       CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0),
                       CGPoint(x: -5, y: 9)] {
            let rect = SocialCropMath.rect(sourceSize: source, targetAspect: 1, zoom: 2, center: center)
            XCTAssertGreaterThanOrEqual(rect.minX, -0.0001)
            XCTAssertGreaterThanOrEqual(rect.minY, -0.0001)
            XCTAssertLessThanOrEqual(rect.maxX, 1.0001)
            XCTAssertLessThanOrEqual(rect.maxY, 1.0001)
        }
    }

    /// The normalized rect's own aspect is the target aspect expressed in
    /// SOURCE units, which is what the pixel crop then yields — the property
    /// that matters is that it's constant across zoom.
    func testAspectIsConstantAcrossZoom() {
        let source = CGSize(width: 3000, height: 4000)
        var ratios: [CGFloat] = []
        for zoom: CGFloat in [1, 1.5, 2, 3, 4] {
            let rect = SocialCropMath.rect(sourceSize: source, targetAspect: 1,
                                           zoom: zoom, center: CGPoint(x: 0.5, y: 0.5))
            ratios.append(rect.width / rect.height)
        }
        for r in ratios { XCTAssertEqual(r, ratios[0], accuracy: 0.0001) }
        // A 1:1 crop out of a 3:4 (portrait) source spans the full width and
        // 3/4 of the height, so the NORMALIZED rect reads 4:3.
        XCTAssertEqual(ratios[0], 4000.0 / 3000.0, accuracy: 0.0001)
    }

    func testZoomShrinksTheVisibleRect() {
        let source = CGSize(width: 1000, height: 1000)
        let one = SocialCropMath.rect(sourceSize: source, targetAspect: 1, zoom: 1,
                                      center: CGPoint(x: 0.5, y: 0.5))
        let two = SocialCropMath.rect(sourceSize: source, targetAspect: 1, zoom: 2,
                                      center: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(two.width, one.width / 2, accuracy: 0.0001)
        // Out-of-range zooms clamp rather than run away.
        let huge = SocialCropMath.rect(sourceSize: source, targetAspect: 1, zoom: 99,
                                       center: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(huge.width, one.width / 4, accuracy: 0.0001)
    }

    func testComposedCropAgainstNilExisting() {
        let social = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.6)
        XCTAssertEqual(SocialCropMath.composedCrop(existing: nil, social: social), social)
    }

    func testComposedCropStaysInsideAPreExistingCrop() {
        let existing = CGRect(x: 0, y: 0, width: 0.5, height: 1.0)
        let social = CGRect(x: 0, y: 0.25, width: 1.0, height: 0.5)
        let composed = SocialCropMath.composedCrop(existing: existing, social: social)
        XCTAssertGreaterThanOrEqual(composed.minX, existing.minX - 0.0001)
        XCTAssertLessThanOrEqual(composed.maxX, existing.maxX + 0.0001)
        XCTAssertGreaterThanOrEqual(composed.minY, existing.minY - 0.0001)
        XCTAssertLessThanOrEqual(composed.maxY, existing.maxY + 0.0001)
        XCTAssertEqual(composed, CGRect(x: 0, y: 0.25, width: 0.5, height: 0.5))
    }

    func testDegenerateSizesClampNeverNaN() {
        let zeroSource = SocialCropMath.rect(sourceSize: .zero, targetAspect: 1, zoom: 1,
                                             center: CGPoint(x: 0.5, y: 0.5))
        XCTAssertFalse(zeroSource.width.isNaN)
        XCTAssertEqual(zeroSource, CGRect(x: 0, y: 0, width: 1, height: 1))
        let zeroAspect = SocialCropMath.rect(sourceSize: CGSize(width: 100, height: 100),
                                             targetAspect: 0, zoom: 1, center: CGPoint(x: 0.5, y: 0.5))
        XCTAssertFalse(zeroAspect.height.isNaN)
        XCTAssertEqual(zeroAspect, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testZoomRangeIsOneToFour() {
        XCTAssertEqual(SocialCropMath.zoomRange, 1...4)
    }

    // MARK: - How much a fixed frame throws away

    func testNothingIsLostWhenTheAspectsMatch() {
        XCTAssertEqual(SocialCropMath.croppedAwayFraction(sourceAspect: 1.5, targetAspect: 1.5),
                       0, accuracy: 0.0001)
    }

    /// A 3:2 landscape into a 4:5 portrait frame: the classic Instagram case.
    func testLandscapeIntoPortraitLosesMostOfTheWidth() {
        let lost = SocialCropMath.croppedAwayFraction(sourceAspect: 1.5, targetAspect: 0.8)
        XCTAssertEqual(lost, 1 - (0.8 / 1.5), accuracy: 0.0001)
        XCTAssertGreaterThan(lost, 0.4)
    }

    func testPortraitIntoLandscapeLosesHeight() {
        let lost = SocialCropMath.croppedAwayFraction(sourceAspect: 0.5, targetAspect: 1.91)
        XCTAssertEqual(lost, 1 - (0.5 / 1.91), accuracy: 0.0001)
    }

    /// Symmetric: swapping the two aspects loses the same proportion.
    func testTheLossIsSymmetric() {
        XCTAssertEqual(SocialCropMath.croppedAwayFraction(sourceAspect: 2, targetAspect: 1),
                       SocialCropMath.croppedAwayFraction(sourceAspect: 1, targetAspect: 2),
                       accuracy: 0.0001)
    }

    func testDegenerateAspectsLoseNothingRatherThanReturningNaN() {
        for (s, t) in [(CGFloat(0), CGFloat(1)), (1, 0), (.infinity, 1), (1, .nan)] {
            let v = SocialCropMath.croppedAwayFraction(sourceAspect: s, targetAspect: t)
            XCTAssertFalse(v.isNaN)
            XCTAssertEqual(v, 0, accuracy: 0.0001)
        }
    }
}
