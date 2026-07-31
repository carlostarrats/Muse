import XCTest
@testable import Muse

final class CurveLUTTests: XCTestCase {
    func testEmptyPointsProducesIdentityLUT() {
        let lut = CurveLUT.build(points: [])
        XCTAssertEqual(lut.count, CurveLUT.entryCount)
        XCTAssertEqual(lut.first!, 0, accuracy: 0.01)
        XCTAssertEqual(lut.last!, 1, accuracy: 0.01)
        XCTAssertEqual(lut[512], Float(512) / Float(CurveLUT.entryCount - 1), accuracy: 0.02)
    }

    func testSinglePointIsStillIdentity() {
        let lut = CurveLUT.build(points: [CurveParams.Point(x: 0.5, y: 0.9)])
        XCTAssertEqual(lut.last!, 1, accuracy: 0.01)
    }

    func testEndpointsAreExact() {
        let points = [CurveParams.Point(x: 0, y: 0.2), CurveParams.Point(x: 1, y: 0.9)]
        let lut = CurveLUT.build(points: points)
        XCTAssertEqual(lut.first!, 0.2, accuracy: 0.01)
        XCTAssertEqual(lut.last!, 0.9, accuracy: 0.01)
    }

    /// The reason this is a MONOTONE spline: a plain cubic Hermite overshoots
    /// between control points, so a rising curve can dip — a visible band of
    /// inverted contrast in a smooth gradient.
    func testMonotoneInputProducesMonotoneOutput() {
        let points = [
            CurveParams.Point(x: 0, y: 0.0), CurveParams.Point(x: 0.3, y: 0.35),
            CurveParams.Point(x: 0.7, y: 0.6), CurveParams.Point(x: 1, y: 1.0),
        ]
        let lut = CurveLUT.build(points: points)
        for i in 1..<lut.count {
            XCTAssertGreaterThanOrEqual(lut[i], lut[i - 1] - 0.001)
        }
    }

    /// The classic overshoot trap: a near-flat run followed by a steep rise.
    func testFlatThenSteepDoesNotOvershoot() {
        let points = [
            CurveParams.Point(x: 0, y: 0.0), CurveParams.Point(x: 0.4, y: 0.02),
            CurveParams.Point(x: 0.5, y: 0.9), CurveParams.Point(x: 1, y: 1.0),
        ]
        let lut = CurveLUT.build(points: points)
        for i in 1..<lut.count {
            XCTAssertGreaterThanOrEqual(lut[i], lut[i - 1] - 0.001)
            XCTAssertLessThanOrEqual(lut[i], 1.0001)
            XCTAssertGreaterThanOrEqual(lut[i], -0.0001)
        }
    }

    func testDescendingCurveIsMonotoneToo() {
        let points = [CurveParams.Point(x: 0, y: 1), CurveParams.Point(x: 1, y: 0)]
        let lut = CurveLUT.build(points: points)
        for i in 1..<lut.count {
            XCTAssertLessThanOrEqual(lut[i], lut[i - 1] + 0.001)
        }
    }

    func testDuplicateXDoesNotDivideByZero() {
        let points = [
            CurveParams.Point(x: 0, y: 0), CurveParams.Point(x: 0.5, y: 0.4),
            CurveParams.Point(x: 0.5, y: 0.6), CurveParams.Point(x: 1, y: 1),
        ]
        let lut = CurveLUT.build(points: points)
        XCTAssertEqual(lut.count, CurveLUT.entryCount)
        XCTAssertTrue(lut.allSatisfy(\.isFinite))
    }

    func testUnsortedInputIsSorted() {
        let sorted = CurveLUT.build(points: [
            CurveParams.Point(x: 0, y: 0), CurveParams.Point(x: 1, y: 0.5),
        ])
        let unsorted = CurveLUT.build(points: [
            CurveParams.Point(x: 1, y: 0.5), CurveParams.Point(x: 0, y: 0),
        ])
        XCTAssertEqual(sorted, unsorted)
    }

    func testOverCapInputIsToleratedNotCrashed() {
        var points: [CurveParams.Point] = []
        for i in 0...30 { points.append(CurveParams.Point(x: Double(i) / 30, y: Double(i) / 30)) }
        let lut = CurveLUT.build(points: points)
        XCTAssertEqual(lut.count, CurveLUT.entryCount)
        XCTAssertTrue(lut.allSatisfy(\.isFinite))
    }
}
