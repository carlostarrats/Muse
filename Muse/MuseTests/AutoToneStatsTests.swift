//
//  AutoToneStatsTests.swift
//  MuseTests
//
//  Auto-tone's statistics, on synthetic frames — the same style as
//  `HistogramComputeTests`. Every assertion here is a property the button's
//  behaviour depends on, not a snapshot of today's constants.
//

import XCTest
@testable import Muse

final class AutoToneStatsTests: XCTestCase {

    /// A flat mid-grey frame is already correctly exposed and neutral — every
    /// output must be ~0, or Auto would "fix" a photo that is already right.
    func testNeutralGreyProducesNoChange() {
        let px = Self.solid(r: 128, g: 128, b: 128, count: 64 * 64)
        let r = AutoToneStats.compute(rgba8: px, width: 64, height: 64)
        XCTAssertEqual(r.exposureEV, 0, accuracy: 0.2)
        XCTAssertEqual(r.temperature, 0, accuracy: 0.02)
        XCTAssertEqual(r.tint, 0, accuracy: 0.02)
    }

    /// A dark frame must be pushed UP, never down.
    func testDarkFrameRaisesExposure() {
        let px = Self.solid(r: 40, g: 40, b: 40, count: 64 * 64)
        let r = AutoToneStats.compute(rgba8: px, width: 64, height: 64)
        XCTAssertGreaterThan(r.exposureEV, 0.5)
    }

    /// A blown frame must be pulled DOWN.
    func testBrightFrameLowersExposure() {
        let px = Self.solid(r: 225, g: 225, b: 225, count: 64 * 64)
        let r = AutoToneStats.compute(rgba8: px, width: 64, height: 64)
        XCTAssertLessThan(r.exposureEV, -0.5)
    }

    /// A warm cast (red high, blue low) must be corrected COOLER, i.e. a
    /// NEGATIVE temperature. A sign error here doubles the cast instead of
    /// removing it, which is why this is pinned.
    func testWarmCastIsCorrectedCooler() {
        let px = Self.solid(r: 200, g: 150, b: 100, count: 64 * 64)
        let r = AutoToneStats.compute(rgba8: px, width: 64, height: 64)
        XCTAssertLessThan(r.temperature, -0.05)
    }

    /// And the mirror: a cool cast is corrected warmer.
    func testCoolCastIsCorrectedWarmer() {
        let px = Self.solid(r: 100, g: 150, b: 200, count: 64 * 64)
        let r = AutoToneStats.compute(rgba8: px, width: 64, height: 64)
        XCTAssertGreaterThan(r.temperature, 0.05)
    }

    /// A low-contrast frame (everything crammed into a narrow mid band) must
    /// open the black and white points outward.
    func testLowContrastOpensBlackAndWhitePoints() {
        var px: [UInt8] = []
        px.reserveCapacity(64 * 64 * 4)
        for i in 0..<(64 * 64) {
            let v = UInt8(110 + (i % 30))          // ~110…139
            px += [v, v, v, 255]
        }
        let r = AutoToneStats.compute(rgba8: px, width: 64, height: 64)
        XCTAssertGreaterThan(r.whites, 0.05)
        XCTAssertLessThan(r.blacks, -0.05)
    }

    /// Idempotence at the statistics level: identical input, identical output.
    /// The session-level guarantee (measure the ORIGINAL, always) rests on it.
    func testDeterministic() {
        let px = Self.solid(r: 90, g: 120, b: 160, count: 32 * 32)
        let a = AutoToneStats.compute(rgba8: px, width: 32, height: 32)
        let b = AutoToneStats.compute(rgba8: px, width: 32, height: 32)
        XCTAssertEqual(a, b)
    }

    /// Degenerate input must not crash, divide by zero, or emit NaN.
    func testEmptyInputIsNeutral() {
        let r = AutoToneStats.compute(rgba8: [], width: 0, height: 0)
        XCTAssertEqual(r, .none)
        XCTAssertFalse(r.temperature.isNaN)
    }

    /// A buffer shorter than width×height×4 must be rejected rather than read
    /// past its end.
    func testTruncatedBufferIsRejected() {
        let r = AutoToneStats.compute(rgba8: [1, 2, 3, 4], width: 64, height: 64)
        XCTAssertEqual(r, .none)
    }

    /// Pure black must not produce an infinite exposure lift.
    func testPureBlackStaysFinite() {
        let px = Self.solid(r: 0, g: 0, b: 0, count: 16 * 16)
        let r = AutoToneStats.compute(rgba8: px, width: 16, height: 16)
        XCTAssertTrue(r.exposureEV.isFinite)
        XCTAssertLessThanOrEqual(r.exposureEV, 5)
    }

    /// Every field stays inside the slider ranges the editor binds to.
    func testAllFieldsStayWithinSliderRanges() {
        for v in stride(from: 0, through: 255, by: 15) {
            let px = Self.solid(r: UInt8(v), g: UInt8(255 - v), b: UInt8(v / 2),
                                count: 16 * 16)
            let r = AutoToneStats.compute(rgba8: px, width: 16, height: 16)
            XCTAssertTrue((-5...5).contains(r.exposureEV), "exposure \(r.exposureEV)")
            XCTAssertTrue((-1...1).contains(r.contrast), "contrast \(r.contrast)")
            XCTAssertTrue((-1...1).contains(r.blacks), "blacks \(r.blacks)")
            XCTAssertTrue((-1...1).contains(r.whites), "whites \(r.whites)")
            XCTAssertTrue((-1...1).contains(r.temperature), "temp \(r.temperature)")
            XCTAssertTrue((-1...1).contains(r.tint), "tint \(r.tint)")
        }
    }

    /// REGRESSION: Auto Light used to flatten every photo it touched.
    ///
    /// `targetSpread` was 0.62 while a normal photo measures ~0.9, so the
    /// contrast term went negative on almost everything. Contrast is now
    /// clamped non-negative — Auto may ADD contrast to a genuinely flat frame
    /// and must never TAKE it from a photo that already has it.
    func testContrastIsNeverNegative() {
        // A full-range frame: a black half and a white half, spread ~1.0.
        var px: [UInt8] = []
        for i in 0..<(64 * 64) {
            let v: UInt8 = i % 2 == 0 ? 4 : 250
            px += [v, v, v, 255]
        }
        let r = AutoToneStats.compute(rgba8: px, width: 64, height: 64)
        XCTAssertGreaterThanOrEqual(r.contrast, 0,
                                    "Auto must never remove contrast — this is the flatness bug")
    }

    /// And across a wide sweep of synthetic frames, never negative.
    func testContrastStaysNonNegativeAcrossManyFrames() {
        for centre in stride(from: 20, through: 235, by: 15) {
            for width in [2, 10, 40, 90] {
                var px: [UInt8] = []
                for i in 0..<(32 * 32) {
                    let v = UInt8(max(0, min(255, centre + (i % width) - width / 2)))
                    px += [v, v, v, 255]
                }
                let r = AutoToneStats.compute(rgba8: px, width: 32, height: 32)
                XCTAssertGreaterThanOrEqual(r.contrast, 0, "centre \(centre) width \(width)")
                XCTAssertLessThanOrEqual(r.contrast, 0.6)
            }
        }
    }

    /// A genuinely flat frame still gets help.
    func testFlatFrameStillGainsContrast() {
        var px: [UInt8] = []
        for i in 0..<(64 * 64) {
            let v = UInt8(118 + (i % 12))          // a very narrow band
            px += [v, v, v, 255]
        }
        let r = AutoToneStats.compute(rgba8: px, width: 64, height: 64)
        XCTAssertGreaterThan(r.contrast, 0.2)
    }

    /// Exposure is damped and capped, so a deliberately high- or low-key frame
    /// is nudged rather than dragged to mid-grey.
    func testExposureIsDampedAndCapped() {
        let dark = AutoToneStats.compute(rgba8: Self.solid(r: 3, g: 3, b: 3, count: 32 * 32),
                                         width: 32, height: 32)
        XCTAssertLessThanOrEqual(dark.exposureEV, AutoToneStats.exposureLimit)
        let bright = AutoToneStats.compute(rgba8: Self.solid(r: 252, g: 252, b: 252,
                                                             count: 32 * 32),
                                           width: 32, height: 32)
        XCTAssertGreaterThanOrEqual(bright.exposureEV, -AutoToneStats.exposureLimit)
    }

    /// Blacks only ever darken and whites only ever brighten — the two are an
    /// auto-LEVELS expansion, so a sign flip would invert the whole point.
    func testBlackAndWhitePointsMoveOnlyOutward() {
        for v in stride(from: 10, through: 245, by: 15) {
            let r = AutoToneStats.compute(
                rgba8: Self.solid(r: UInt8(v), g: UInt8(v), b: UInt8(v), count: 16 * 16),
                width: 16, height: 16)
            XCTAssertLessThanOrEqual(r.blacks, 0, "value \(v)")
            XCTAssertGreaterThanOrEqual(r.whites, 0, "value \(v)")
        }
    }

    private static func solid(r: UInt8, g: UInt8, b: UInt8, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count * 4)
        for _ in 0..<count { out += [r, g, b, 255] }
        return out
    }
}
