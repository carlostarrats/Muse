import XCTest
@testable import Muse

final class CanvasPointMathTests: XCTestCase {
    private let fit = CGRect(x: 0, y: 0, width: 100, height: 100)

    func testCenterCanvasPointMapsToCenterOfImageAtFitZoom() {
        let result = CanvasPointMath.imagePoint(fromCanvasPoint: CGPoint(x: 50, y: 50),
                                                fit: fit, zoom: 1, pan: .zero)
        XCTAssertEqual(result?.x ?? -1, 0.5, accuracy: 0.01)
        XCTAssertEqual(result?.y ?? -1, 0.5, accuracy: 0.01)
    }

    func testCornersMapToUnitCorners() {
        let topLeft = CanvasPointMath.imagePoint(fromCanvasPoint: CGPoint(x: 0, y: 0),
                                                 fit: fit, zoom: 1, pan: .zero)
        XCTAssertEqual(topLeft?.x ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(topLeft?.y ?? -1, 0, accuracy: 0.001)
        let bottomRight = CanvasPointMath.imagePoint(fromCanvasPoint: CGPoint(x: 100, y: 100),
                                                     fit: fit, zoom: 1, pan: .zero)
        XCTAssertEqual(bottomRight?.x ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(bottomRight?.y ?? -1, 1, accuracy: 0.001)
    }

    /// Out-of-image returns nil rather than clamping: sampling a click that
    /// landed on the backdrop would set white balance from the backdrop.
    func testOutOfImagePointReturnsNil() {
        XCTAssertNil(CanvasPointMath.imagePoint(fromCanvasPoint: CGPoint(x: 500, y: 500),
                                                fit: fit, zoom: 1, pan: .zero))
        XCTAssertNil(CanvasPointMath.imagePoint(fromCanvasPoint: CGPoint(x: -1, y: 50),
                                                fit: fit, zoom: 1, pan: .zero))
    }

    /// Zoom is about the fitted rect's CENTRE, matching the canvas — scaling
    /// about the origin instead drifts the sample further off as you zoom in.
    func testZoomIsAboutTheCenter() {
        let result = CanvasPointMath.imagePoint(fromCanvasPoint: CGPoint(x: 50, y: 50),
                                                fit: fit, zoom: 2, pan: .zero)
        XCTAssertEqual(result?.x ?? -1, 0.5, accuracy: 0.01)
        XCTAssertEqual(result?.y ?? -1, 0.5, accuracy: 0.01)
    }

    func testZoomedEdgeFallsOutsideTheCanvasClick() {
        // At 2x the image's left edge sits at canvas x = -50, so a click at
        // x = 0 is a QUARTER of the way in, not at the edge.
        let result = CanvasPointMath.imagePoint(fromCanvasPoint: CGPoint(x: 0, y: 50),
                                                fit: fit, zoom: 2, pan: .zero)
        XCTAssertEqual(result?.x ?? -1, 0.25, accuracy: 0.01)
    }

    func testPanShiftsTheMapping() {
        let result = CanvasPointMath.imagePoint(fromCanvasPoint: CGPoint(x: 50, y: 50),
                                                fit: fit, zoom: 1,
                                                pan: CGSize(width: 25, height: 0))
        XCTAssertEqual(result?.x ?? -1, 0.25, accuracy: 0.01)
    }

    func testDegenerateInputsReturnNil() {
        XCTAssertNil(CanvasPointMath.imagePoint(fromCanvasPoint: .zero,
                                                fit: .zero, zoom: 1, pan: .zero))
        XCTAssertNil(CanvasPointMath.imagePoint(fromCanvasPoint: CGPoint(x: 50, y: 50),
                                                fit: fit, zoom: 0, pan: .zero))
    }
}

final class WBEyedropperTests: XCTestCase {
    /// A neutral gray sample means "this is already correct" — the solve must
    /// leave both sliders alone rather than nudging them.
    func testNeutralGrayResolvesToNoOffset() {
        let solved = WBEyedropper.solve(sampledColor: (r: 0.5, g: 0.5, b: 0.5))
        XCTAssertEqual(solved.temperature, 0, accuracy: 0.01)
        XCTAssertEqual(solved.tint, 0, accuracy: 0.01)
    }

    /// A sample that's too WARM (red-heavy) has to pull temperature DOWN —
    /// getting this sign wrong doubles the cast instead of removing it.
    func testWarmSampleCoolsTheImage() {
        let solved = WBEyedropper.solve(sampledColor: (r: 0.8, g: 0.5, b: 0.3))
        XCTAssertLessThan(solved.temperature, 0)
    }

    func testCoolSampleWarmsTheImage() {
        let solved = WBEyedropper.solve(sampledColor: (r: 0.3, g: 0.5, b: 0.8))
        XCTAssertGreaterThan(solved.temperature, 0)
    }

    func testMagentaSampleMovesTintTowardGreen() {
        let solved = WBEyedropper.solve(sampledColor: (r: 0.7, g: 0.4, b: 0.7))
        XCTAssertLessThan(solved.tint, 0)
    }

    func testResultIsAlwaysInSliderRange() {
        for sample in [(r: 1.0, g: 0.001, b: 0.001), (r: 0.0, g: 0.0, b: 0.0),
                       (r: 0.001, g: 1.0, b: 0.001)] {
            let solved = WBEyedropper.solve(sampledColor: sample)
            XCTAssertTrue((-1...1).contains(solved.temperature))
            XCTAssertTrue((-1...1).contains(solved.tint))
        }
    }
}
