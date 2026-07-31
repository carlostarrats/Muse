import XCTest
@testable import Muse

final class MiredMappingTests: XCTestCase {
    /// The bug this pins against: a Kelvin-linear mapping is warm/cool
    /// ASYMMETRIC, because equal Kelvin steps are wildly unequal perceptually.
    /// Equal slider steps must be equal mired steps in both directions.
    func testWarmAndCoolAreSymmetricInMiredSpace() {
        let warm = MiredMapping.miredOffset(forSliderValue: 1.0)
        let cool = MiredMapping.miredOffset(forSliderValue: -1.0)
        XCTAssertEqual(warm, -cool, accuracy: 0.5)
        XCTAssertGreaterThan(warm, 0)
    }

    func testZeroSliderIsIdentity() {
        XCTAssertEqual(MiredMapping.miredOffset(forSliderValue: 0), 0, accuracy: 0.01)
    }

    func testMappingIsLinearInMiredAcrossTheSlider() {
        let half = MiredMapping.miredOffset(forSliderValue: 0.5)
        let full = MiredMapping.miredOffset(forSliderValue: 1.0)
        XCTAssertEqual(full / 2, half, accuracy: 0.5)
    }

    func testPlusOneReachesTheWarmTarget() {
        let offset = MiredMapping.miredOffset(forSliderValue: 1.0)
        let kelvin = MiredMapping.kelvin(from: 6500, miredOffset: offset)
        XCTAssertEqual(kelvin, MiredMapping.warmTargetKelvin, accuracy: 1.0)
        XCTAssertLessThan(kelvin, 6500, "positive slider must be WARMER")
    }

    /// The range is derived from the floor, so a full-cool slider lands ON the
    /// floor rather than being clamped back to it — clamping is what made the
    /// two directions asymmetric.
    func testMinusOneLandsExactlyOnTheFloor() {
        let offset = MiredMapping.miredOffset(forSliderValue: -1.0)
        XCTAssertEqual(MiredMapping.d65Mired + offset, MiredMapping.miredFloor, accuracy: 0.01)
    }

    func testOutOfRangeSliderIsClamped() {
        XCTAssertEqual(MiredMapping.miredOffset(forSliderValue: -50),
                       MiredMapping.miredOffset(forSliderValue: -1), accuracy: 0.01)
        XCTAssertEqual(MiredMapping.miredOffset(forSliderValue: 50),
                       MiredMapping.miredOffset(forSliderValue: 1), accuracy: 0.01)
    }

    func testKelvinRoundTripsThroughZeroOffset() {
        XCTAssertEqual(MiredMapping.kelvin(from: 5000, miredOffset: 0), 5000, accuracy: 0.01)
    }
}
