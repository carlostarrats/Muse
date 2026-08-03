//
//  HDRDecodeTests.swift
//  MuseTests
//
//  The decode seam. The load-bearing test here is
//  `testToneMapRollsOffRatherThanClamping` — a clamp and a tone map both keep
//  values at or below 1.0, so "did it clip" can only be told apart by whether
//  two different bright values are still different afterwards.
//

import XCTest
import CoreImage
import CoreGraphics
@testable import Muse

final class HDRDecodeTests: XCTestCase {

    // MARK: - Inspect

    func testSDRFileReportsNoHeadroom() throws {
        let info = HDRDecode.info(url: try HDRTestFixtures.sdrPNG(value: 0.5))
        XCTAssertEqual(info.headroom, 1.0, accuracy: 0.01)
        XCTAssertFalse(info.isHDR)
    }

    func testHDRFileReportsHeadroomAboveOne() throws {
        let info = HDRDecode.info(url: try HDRTestFixtures.hdrHEIC(value: 4.0))
        XCTAssertGreaterThan(info.headroom, 1.0)
        XCTAssertTrue(info.isHDR)
    }

    func testUnreadableFileIsSDRRatherThanAnError() {
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).heic")
        XCTAssertFalse(HDRDecode.info(url: missing).isHDR)
    }

    // MARK: - Decode

    func testDecodePreservesValuesAboveOne() throws {
        let url = try HDRTestFixtures.hdrHEIC(value: 4.0)
        let cg = try XCTUnwrap(HDRDecode.decode(url: url, maxPixel: 0))
        let px = HDRTestFixtures.firstPixel(CIImage(cgImage: cg))
        XCTAssertGreaterThan(px.r, 2.0, "HDR decode must not clamp a 4.0 pixel")
    }

    func testDecodeHonoursMaxPixel() throws {
        let url = try HDRTestFixtures.hdrHEIC(value: 4.0)
        let cg = try XCTUnwrap(HDRDecode.decode(url: url, maxPixel: 8))
        XCTAssertLessThanOrEqual(max(cg.width, cg.height), 8)
    }

    // MARK: - Tone map

    func testToneMapNeverExceedsOne() {
        let bright = CIImage(color: CIColor(red: 4.0, green: 4.0, blue: 4.0,
                                            colorSpace: HDRTestFixtures.linearSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let px = HDRTestFixtures.firstPixel(HDRDecode.toneMappedToSDR(bright, headroom: 4.0))
        XCTAssertLessThanOrEqual(px.r, 1.001)
        XCTAssertLessThanOrEqual(px.g, 1.001)
        XCTAssertLessThanOrEqual(px.b, 1.001)
    }

    /// A clamp maps 2.0 and 4.0 onto the SAME value. A roll-off keeps them
    /// ordered and visibly apart. This is the regression gate on going back to
    /// `createCGImage(colorSpace: sRGB)`, which was measured hard-clipping.
    func testToneMapRollsOffRatherThanClamping() {
        let two = mappedValue(2.0, headroom: 4.0)
        let four = mappedValue(4.0, headroom: 4.0)
        XCTAssertGreaterThan(four, two, "4.0 must stay brighter than 2.0 after tone mapping")
        XCTAssertGreaterThan(four - two, 0.01, "the gap must be visible, not float noise")
    }

    func testHeadroomOfOneIsIdentity() {
        XCTAssertEqual(mappedValue(0.5, headroom: 1.0), 0.5, accuracy: 0.01,
                       "an SDR image must pass through untouched")
    }

    func testMidtonesSurviveToneMapping() {
        // The bound separates a real tone CURVE from the last-resort linear
        // divide, which lands a midtone at exactly 0.125 here (0.5 / 4.0) and
        // makes the whole photo read as underexposed. Both real branches clear
        // it with room: `CIToneMapHeadroom` measures 0.297 and the Reinhard
        // fallback 0.556. It is deliberately NOT tight around either — the two
        // curves differ by design, and pinning one would fail on the other.
        let mid = mappedValue(0.5, headroom: 4.0)
        XCTAssertGreaterThan(mid, 0.2, "a midtone must not be crushed toward the linear divide")
        XCTAssertLessThan(mid, 0.9)
    }

    private func mappedValue(_ value: CGFloat, headroom: CGFloat) -> Float {
        let image = CIImage(color: CIColor(red: value, green: value, blue: value,
                                           colorSpace: HDRTestFixtures.linearSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        return HDRTestFixtures.firstPixel(HDRDecode.toneMappedToSDR(image, headroom: headroom)).r
    }
}
