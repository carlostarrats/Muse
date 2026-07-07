import XCTest
@testable import Muse

final class ColorDistanceTests: XCTestCase {

    func testWhiteIsL100() {
        let lab = LabColor(rgb: RGB(r: 1, g: 1, b: 1))
        XCTAssertEqual(lab.L, 100, accuracy: 0.5)
        XCTAssertEqual(lab.a, 0, accuracy: 0.5)
        XCTAssertEqual(lab.b, 0, accuracy: 0.5)
    }

    func testBlackIsL0() {
        let lab = LabColor(rgb: RGB(r: 0, g: 0, b: 0))
        XCTAssertEqual(lab.L, 0, accuracy: 0.5)
        XCTAssertEqual(lab.a, 0, accuracy: 0.5)
        XCTAssertEqual(lab.b, 0, accuracy: 0.5)
    }

    func testMidGreyIsNeutralMidL() {
        let lab = LabColor(rgb: RGB(r: 0.5, g: 0.5, b: 0.5))
        XCTAssertEqual(lab.a, 0, accuracy: 0.5)   // grey has no chroma
        XCTAssertEqual(lab.b, 0, accuracy: 0.5)
        XCTAssertTrue(lab.L > 45 && lab.L < 60, "mid grey L≈53, got \(lab.L)")
    }

    func testSelfDistanceIsZero() {
        let red = LabColor(rgb: RGB(r: 1, g: 0, b: 0))
        XCTAssertEqual(ColorDistance.deltaE(red, red), 0, accuracy: 0.0001)
    }

    func testDistanceIsSymmetric() {
        let red = LabColor(rgb: RGB(r: 1, g: 0, b: 0))
        let green = LabColor(rgb: RGB(r: 0, g: 1, b: 0))
        XCTAssertEqual(ColorDistance.deltaE(red, green),
                       ColorDistance.deltaE(green, red), accuracy: 0.0001)
    }

    func testPrimariesAreFarApart() {
        let red = LabColor(rgb: RGB(r: 1, g: 0, b: 0))
        let blue = LabColor(rgb: RGB(r: 0, g: 0, b: 1))
        // Distinct primaries are well past the "near" threshold.
        XCTAssertGreaterThan(ColorDistance.deltaE(red, blue), ColorDistance.nearThreshold)
    }

    func testNearThresholdIsPositive() {
        XCTAssertGreaterThan(ColorDistance.nearThreshold, 0)
    }

    // CIEDE2000 reference pairs from Sharma et al. (2005), the canonical
    // implementation-validation dataset. Locks the ΔE2000 math.
    func testCIEDE2000ReferencePair1() {
        let a = LabColor(L: 50, a: 2.6772, b: -79.7751)
        let b = LabColor(L: 50, a: 0, b: -82.7485)
        XCTAssertEqual(ColorDistance.deltaE(a, b), 2.0425, accuracy: 0.001)
    }

    func testCIEDE2000ReferencePair2() {
        let a = LabColor(L: 50, a: -1.3802, b: -84.2814)
        let b = LabColor(L: 50, a: 0, b: -82.7485)
        XCTAssertEqual(ColorDistance.deltaE(a, b), 1.0000, accuracy: 0.001)
    }

    func testCIEDE2000ReferencePair3() {
        let a = LabColor(L: 50, a: 2.5, b: 0)
        let b = LabColor(L: 73, a: 25, b: -18)
        XCTAssertEqual(ColorDistance.deltaE(a, b), 27.1492, accuracy: 0.001)
    }
}
