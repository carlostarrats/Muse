import XCTest
@testable import Muse

/// The CPU truth the Metal kernel mirrors. The two can't share code, so these
/// pin the formula and the render goldens pin the agreement.
final class ToneZoneMathTests: XCTestCase {

    /// Partition of unity: the whole control depends on it. If the weights
    /// didn't sum to 1, equal gains across all nine zones would be something
    /// other than a plain exposure shift.
    func testWeightsSumToOneAcrossFullEVRange() {
        var ev = ToneZoneMath.evFloor
        while ev <= ToneZoneMath.evCeiling {
            let weights = ToneZoneMath.weights(forEV: ev)
            XCTAssertEqual(weights.count, ToneZoneMath.zoneCount)
            XCTAssertEqual(weights.reduce(0, +), 1.0, accuracy: 1e-9, "EV \(ev)")
            ev += 0.25
        }
    }

    func testWeightsAreNonNegative() {
        XCTAssertTrue(ToneZoneMath.weights(forEV: -3.5).allSatisfy { $0 >= 0 })
    }

    func testEVBelowFloorClampsToEndZone() {
        XCTAssertEqual(ToneZoneMath.weights(forEV: -20),
                       ToneZoneMath.weights(forEV: ToneZoneMath.evFloor))
    }

    func testEVAboveCeilingClampsToEndZone() {
        XCTAssertEqual(ToneZoneMath.weights(forEV: 20),
                       ToneZoneMath.weights(forEV: ToneZoneMath.evCeiling))
    }

    func testZoneIndexAtFloorIsZero() {
        XCTAssertEqual(ToneZoneMath.zoneIndex(forEV: ToneZoneMath.evFloor), 0)
    }

    func testZoneIndexAtCeilingIsLast() {
        XCTAssertEqual(ToneZoneMath.zoneIndex(forEV: ToneZoneMath.evCeiling),
                       ToneZoneMath.zoneCount - 1)
    }

    func testZoneIndexMidpointIsMiddleZone() {
        let mid = (ToneZoneMath.evFloor + ToneZoneMath.evCeiling) / 2
        XCTAssertEqual(ToneZoneMath.zoneIndex(forEV: mid), ToneZoneMath.zoneCount / 2)
    }

    func testZoneIndexIsMonotonicNondecreasing() {
        var previous = ToneZoneMath.zoneIndex(forEV: ToneZoneMath.evFloor)
        var ev = ToneZoneMath.evFloor
        while ev <= ToneZoneMath.evCeiling {
            let idx = ToneZoneMath.zoneIndex(forEV: ev)
            XCTAssertGreaterThanOrEqual(idx, previous)
            previous = idx
            ev += 0.5
        }
    }

    /// The neutrality golden's arithmetic half: zero gains means zero offset
    /// EVERYWHERE, exactly, not approximately.
    func testGainEVZeroAtAllZeroGains() {
        let gains = [Double](repeating: 0, count: ToneZoneMath.zoneCount)
        for ev in stride(from: -9.0, through: 1.0, by: 0.5) {
            XCTAssertEqual(ToneZoneMath.gainEV(forEV: ev, gains: gains), 0, accuracy: 1e-12)
        }
    }

    func testGainEVAtZoneCenterEqualsThatZonesGainTimesMaxZoneEV() {
        var gains = [Double](repeating: 0, count: ToneZoneMath.zoneCount)
        gains[0] = 1.0
        XCTAssertEqual(ToneZoneMath.gainEV(forEV: ToneZoneMath.zoneCenterEV(0), gains: gains),
                       ToneZoneMath.maxZoneEV, accuracy: 1e-9)
    }

    func testGainEVIsLinearInGainMagnitude() {
        var half = [Double](repeating: 0, count: ToneZoneMath.zoneCount); half[4] = 0.5
        var full = [Double](repeating: 0, count: ToneZoneMath.zoneCount); full[4] = 1.0
        let center = ToneZoneMath.zoneCenterEV(4)
        XCTAssertEqual(ToneZoneMath.gainEV(forEV: center, gains: full),
                       ToneZoneMath.gainEV(forEV: center, gains: half) * 2, accuracy: 1e-9)
    }

    /// Equal gains everywhere is a plain exposure shift — the property the
    /// partition of unity buys, stated as a test so a future weighting change
    /// can't quietly break it.
    func testEqualGainsAreAPlainExposureShift() {
        let gains = [Double](repeating: 0.5, count: ToneZoneMath.zoneCount)
        for ev in stride(from: ToneZoneMath.evFloor, through: ToneZoneMath.evCeiling, by: 0.5) {
            XCTAssertEqual(ToneZoneMath.gainEV(forEV: ev, gains: gains),
                           0.5 * ToneZoneMath.maxZoneEV, accuracy: 1e-9)
        }
    }

    /// A wrong-length array from a hand-edited sidecar must be normalized, not
    /// crash the renderer.
    func testGainEVNormalizesAWrongLengthGainsArray() {
        XCTAssertEqual(ToneZoneMath.gainEV(forEV: -8, gains: [1.0]),
                       ToneZoneMath.maxZoneEV, accuracy: 1e-9)
    }
}
