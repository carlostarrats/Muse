//
//  HistogramHeadroomTests.swift
//  MuseTests
//
//  Clipping means "at the top of what this file can hold", not "above 1.0".
//  Without this the editor announced "those areas have lost detail" over every
//  specular highlight in every HDR photo — a confident wrong answer from the
//  panel whose entire job is teaching the user what they're looking at.
//

import XCTest
import CoreGraphics
@testable import Muse

final class HistogramHeadroomTests: XCTestCase {

    private func flat(_ value: Float, count: Int = 4 * 4) -> [Float] {
        var out = [Float]()
        for _ in 0..<count { out.append(contentsOf: [value, value, value, 1.0]) }
        return out
    }

    /// Highlights at 3.5 in a photo whose headroom is 4.0 are NOT clipped —
    /// they are bright, and the file has room for them.
    func testHighlightsBelowHeadroomAreNotClipped() {
        let (_, clipping) = HistogramCompute.compute(
            rgbaFloat: flat(3.5), width: 4, height: 4, headroom: 4.0,
            highThreshold: 0.98, lowThreshold: 0.02)
        XCTAssertEqual(clipping.highR, 0.0, accuracy: 0.001)
        XCTAssertEqual(clipping.highG, 0.0, accuracy: 0.001)
        XCTAssertEqual(clipping.highB, 0.0, accuracy: 0.001)
    }

    /// The same pixel values with NO headroom to hold them ARE clipped.
    func testSameValuesClipWhenThereIsNoHeadroom() {
        let (_, clipping) = HistogramCompute.compute(
            rgbaFloat: flat(3.5), width: 4, height: 4, headroom: 1.0,
            highThreshold: 0.98, lowThreshold: 0.02)
        XCTAssertEqual(clipping.highR, 1.0, accuracy: 0.001)
    }

    /// At the top of the headroom it really is clipping — detail is gone, and
    /// the readout must still say so.
    func testAtTheHeadroomItIsClipped() {
        let (_, clipping) = HistogramCompute.compute(
            rgbaFloat: flat(4.0), width: 4, height: 4, headroom: 4.0,
            highThreshold: 0.98, lowThreshold: 0.02)
        XCTAssertEqual(clipping.highR, 1.0, accuracy: 0.001)
    }

    /// The float path and the byte path must agree on SDR content, or the
    /// numbers would change under the user for no visible reason.
    func testFloatAndByteAgreeOnSDRContent() {
        let bytes = [UInt8](repeating: 128, count: 4 * 4 * 4)
        let (_, a) = HistogramCompute.compute(rgba8: bytes, width: 4, height: 4,
                                              highThreshold: 0.98, lowThreshold: 0.02)
        let (_, b) = HistogramCompute.compute(rgbaFloat: flat(128.0 / 255.0),
                                              width: 4, height: 4, headroom: 1.0,
                                              highThreshold: 0.98, lowThreshold: 0.02)
        XCTAssertEqual(a.highR, b.highR, accuracy: 0.001)
        XCTAssertEqual(a.low, b.low, accuracy: 0.001)
    }

    func testShadowsStillReadAsShadowsUnderHeadroom() {
        let (_, clipping) = HistogramCompute.compute(
            rgbaFloat: flat(0.0), width: 4, height: 4, headroom: 4.0,
            highThreshold: 0.98, lowThreshold: 0.02)
        XCTAssertEqual(clipping.low, 1.0, accuracy: 0.001,
                       "headroom scales the TOP; black is still black")
    }

    func testShortBufferIsEmptyRatherThanACrash() {
        let (histogram, clipping) = HistogramCompute.compute(
            rgbaFloat: [1.0, 1.0], width: 4, height: 4, headroom: 4.0,
            highThreshold: 0.98, lowThreshold: 0.02)
        XCTAssertEqual(histogram, .empty)
        XCTAssertEqual(clipping, .none)
    }
}
