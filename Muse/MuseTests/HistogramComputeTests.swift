import XCTest
@testable import Muse

final class HistogramComputeTests: XCTestCase {

    private func solidBuffer(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: buf.count, by: 4) {
            buf[i] = r; buf[i + 1] = g; buf[i + 2] = b; buf[i + 3] = 255
        }
        return buf
    }

    private func gradientBuffer(width: Int, height: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = UInt8(Double(x) / Double(max(width - 1, 1)) * 255)
                let i = (y * width + x) * 4
                buf[i] = v; buf[i + 1] = v; buf[i + 2] = v; buf[i + 3] = 255
            }
        }
        return buf
    }

    private func compute(_ buf: [UInt8], _ w: Int, _ h: Int)
        -> (histogram: HistogramData, clipping: ClippingStats) {
        HistogramCompute.compute(rgba8: buf, width: w, height: h,
                                 highThreshold: 0.98, lowThreshold: 0.02)
    }

    func testSolidMidGrayFillsOneBinAcrossAllChannels() {
        let (hist, _) = compute(solidBuffer(width: 8, height: 8, r: 128, g: 128, b: 128), 8, 8)
        XCTAssertEqual(hist.r.count, HistogramData.binCount)
        let peak = hist.r.firstIndex(of: hist.r.max()!)!
        XCTAssertEqual(peak, 32, accuracy: 1)
        XCTAssertEqual(hist.g.firstIndex(of: hist.g.max()!)!, peak)
        XCTAssertEqual(hist.b.firstIndex(of: hist.b.max()!)!, peak)
        XCTAssertEqual(hist.r.max()!, 1.0, accuracy: 0.001)
    }

    func testAllWhiteBufferClipsHighOnAllThreeChannels() {
        let (_, clip) = compute(solidBuffer(width: 4, height: 4, r: 255, g: 255, b: 255), 4, 4)
        XCTAssertEqual(clip.highR, 1.0, accuracy: 0.001)
        XCTAssertEqual(clip.highG, 1.0, accuracy: 0.001)
        XCTAssertEqual(clip.highB, 1.0, accuracy: 0.001)
        XCTAssertEqual(clip.low, 0.0, accuracy: 0.001)
    }

    func testAllBlackBufferClipsLowOnly() {
        let (_, clip) = compute(solidBuffer(width: 4, height: 4, r: 0, g: 0, b: 0), 4, 4)
        XCTAssertEqual(clip.low, 1.0, accuracy: 0.001)
        XCTAssertEqual(clip.highR, 0.0, accuracy: 0.001)
    }

    func testMidGrayBufferHasZeroClipping() {
        let (_, clip) = compute(solidBuffer(width: 4, height: 4, r: 128, g: 128, b: 128), 4, 4)
        XCTAssertEqual(clip.highR, 0)
        XCTAssertEqual(clip.low, 0)
    }

    /// A centroid of no pixels is ABSENT, not zero — zero would read as "at the
    /// very top of the frame" and put a spatial claim on nothing.
    func testClipMassCenterYNilWhenFractionIsZero() {
        let (_, clip) = compute(solidBuffer(width: 4, height: 4, r: 128, g: 128, b: 128), 4, 4)
        XCTAssertNil(clip.highMassCenterY)
        XCTAssertNil(clip.lowMassCenterY)
    }

    func testClipMassCenterYIsTopWhenClippedRowsAreAtTop() throws {
        var buf = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for y in 0..<4 {
            for x in 0..<4 {
                let v: UInt8 = y < 2 ? 255 : 128
                let i = (y * 4 + x) * 4
                buf[i] = v; buf[i + 1] = v; buf[i + 2] = v; buf[i + 3] = 255
            }
        }
        let (_, clip) = compute(buf, 4, 4)
        let centerY = try XCTUnwrap(clip.highMassCenterY)
        XCTAssertLessThan(centerY, 0.34)
        XCTAssertEqual(HistogramCompute.frameRegion(forCenterY: centerY), .top)
    }

    func testFrameRegionMappingThirds() {
        XCTAssertEqual(HistogramCompute.frameRegion(forCenterY: 0.1), .top)
        XCTAssertEqual(HistogramCompute.frameRegion(forCenterY: 0.5), .middle)
        XCTAssertEqual(HistogramCompute.frameRegion(forCenterY: 0.9), .bottom)
        XCTAssertNil(HistogramCompute.frameRegion(forCenterY: nil))
    }

    func testGradientHistogramSpreadsAcrossManyBins() {
        let (hist, _) = compute(gradientBuffer(width: 256, height: 4), 256, 4)
        XCTAssertGreaterThan(hist.luma.filter { $0 > 0 }.count, HistogramData.binCount / 2)
    }

    func testDegenerateInputReturnsEmptyStatsRatherThanCrashing() {
        let (hist, clip) = HistogramCompute.compute(rgba8: [], width: 0, height: 0,
                                                    highThreshold: 0.98, lowThreshold: 0.02)
        XCTAssertEqual(hist, .empty)
        XCTAssertEqual(clip, .none)
    }

    /// The stored thresholds must NOT track the editor prefs — a photo_traits
    /// row would otherwise change meaning when a slider moves.
    func testStoredThresholdsAreFixedConstants() {
        XCTAssertEqual(ClippingStats.storedHighThreshold, 254.0 / 255.0)
        XCTAssertEqual(ClippingStats.storedLowThreshold, 2.0 / 255.0)
    }

    func testZoneMassOnSyntheticEVRampSumsToAtMostOne() {
        var evMap = [Float](repeating: 0, count: 16 * 4)
        for y in 0..<4 {
            for x in 0..<16 { evMap[y * 16 + x] = Float(-8.0 + (Double(x) / 15.0) * 8.0) }
        }
        let mass = HistogramCompute.zoneMass(evMap: evMap, width: 16, height: 4)
        XCTAssertEqual(mass.count, ToneZoneParams.zoneCount)
        XCTAssertLessThanOrEqual(mass.reduce(0, +), 1.0001)
        XCTAssertTrue(mass.allSatisfy { $0 >= 0 })
    }

    func testZoneMassOfAUniformEVLandsInTheMatchingZone() {
        let evMap = [Float](repeating: -4, count: 8 * 8)
        let mass = HistogramCompute.zoneMass(evMap: evMap, width: 8, height: 8)
        XCTAssertGreaterThan(mass.reduce(0, +), 0.9)
        XCTAssertEqual(mass.firstIndex(of: mass.max()!), ToneZoneMath.zoneIndex(forEV: -4))
    }

    func testCurveHistogramDerivesFromLumaChannel() {
        let hist = HistogramData(r: .init(repeating: 0, count: 64),
                                 g: .init(repeating: 0, count: 64),
                                 b: .init(repeating: 0, count: 64),
                                 luma: (0..<64).map { Float($0) / 63.0 })
        XCTAssertEqual(HistogramCompute.curveHistogram(from: hist).bins, hist.luma)
    }
}
