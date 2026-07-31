//
//  SharpnessScoreTests.swift
//  MuseTests
//

import XCTest
import CoreGraphics
@testable import Muse

final class SharpnessScoreTests: XCTestCase {

    /// A checkerboard has strong high-frequency edges everywhere → high variance-of-Laplacian.
    private func checkerboard(side: Int = 256, cell: Int = 8) -> CGImage {
        let cs = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(data: nil, width: side, height: side,
                             bitsPerComponent: 8, bytesPerRow: side,
                             space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        var buf = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let on = ((x / cell) + (y / cell)) % 2 == 0
                buf[y * side + x] = on ? 255 : 0
            }
        }
        buf.withUnsafeBytes { ptr in
            ctx.data!.copyMemory(from: ptr.baseAddress!, byteCount: buf.count)
        }
        return ctx.makeImage()!
    }

    /// A flat gray field has zero edges anywhere → variance-of-Laplacian ≈ 0.
    private func flatGray(side: Int = 256, value: UInt8 = 128) -> CGImage {
        let cs = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(data: nil, width: side, height: side,
                             bitsPerComponent: 8, bytesPerRow: side,
                             space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        var buf = [UInt8](repeating: value, count: side * side)
        buf.withUnsafeBytes { ptr in
            ctx.data!.copyMemory(from: ptr.baseAddress!, byteCount: buf.count)
        }
        return ctx.makeImage()!
    }

    func testSharpImageScoresHigherThanFlatImage() {
        let sharp = SharpnessScore.score(checkerboard())
        let flat = SharpnessScore.score(flatGray())
        XCTAssertNotNil(sharp)
        XCTAssertNotNil(flat)
        XCTAssertGreaterThan(sharp!, flat!)
    }

    func testResolutionNormalizationKeepsSameSceneComparable() {
        // Same pattern rendered at 1x and 4x pixel density should score
        // within the compare tie band once downsampled to a fixed long edge.
        let base = SharpnessScore.score(checkerboard(side: 256, cell: 8))!
        let scaled = SharpnessScore.score(checkerboard(side: 1024, cell: 32))!
        XCTAssertEqual(base, scaled, accuracy: 0.5, "same scene at different pixel densities should normalize close")
    }

    func testDegenerateInputReturnsNil() {
        let cs = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(data: nil, width: 4, height: 4,
                             bitsPerComponent: 8, bytesPerRow: 4,
                             space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let tiny = ctx.makeImage()!
        XCTAssertNil(SharpnessScore.score(tiny))
    }

    func testBucketThresholds() {
        XCTAssertEqual(SharpnessScore.bucket(1.0), .soft)
        XCTAssertEqual(SharpnessScore.bucket(SharpnessScore.softCeiling), .soft)
        XCTAssertEqual(SharpnessScore.bucket(3.0), .moderate)
        XCTAssertEqual(SharpnessScore.bucket(SharpnessScore.sharpFloor), .sharp)
        XCTAssertEqual(SharpnessScore.bucket(5.0), .sharp)
    }
}
