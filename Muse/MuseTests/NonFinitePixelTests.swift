//
//  NonFinitePixelTests.swift
//  MuseTests
//
//  A NaN or infinity must not reach an integer conversion.
//
//  `min(max(x, 0), 1)` reads as a sanitizer and is only half of one. It handles
//  the infinities — they clamp to 1 and 0 — and passes NaN straight through,
//  because every comparison against NaN is false and both functions return the
//  other operand's comparison result. The stats tap clamped a float pixel that
//  way and then wrote `UInt8(normalized * 255)`, which TRAPS — "Double value
//  cannot be converted to UInt8 because it is either infinite or NaN". That is
//  a crash on opening a photo, from data the app read off disk.
//
//  Three ways a non-finite value gets into the float render:
//   - a `.cube` LUT whose text says `nan` or `inf`; `Float("nan")` parses
//     happily, so the importer accepted it,
//   - a restored `.muselibrary`, whose `edit_luts` rows land by plain INSERT
//     and never pass the importer at all,
//   - a 32-bit-float source file (TIFF/EXR) that simply contains NaN pixels,
//     which reaches the stats tap with no LUT involved.
//
//  The first two are refused at their boundary; the third can't be, so the
//  conversion itself is made total.
//

import XCTest
import GRDB
@testable import Muse

final class NonFinitePixelTests: XCTestCase {

    // MARK: - The statistics boundary

    private func pixels(_ values: [Float]) -> [Float] {
        var out = [Float]()
        for v in values { out.append(contentsOf: [v, v, v, 1.0]) }
        return out
    }

    /// The trap itself. Before the fix this test does not fail — it CRASHES the
    /// test process, which is exactly what the app did.
    func testNaNPixelDoesNotTrapTheStatsPass() {
        let buffer = pixels([Float.nan, 0.5, 1.0, 0.0,
                             0.25, 0.5, 0.75, 1.0,
                             0, 0, 0, 0,
                             1, 1, 1, 1])
        let (histogram, _) = HistogramCompute.compute(
            rgbaFloat: buffer, width: 4, height: 4, headroom: 1.0,
            highThreshold: 0.98, lowThreshold: 0.02)
        XCTAssertEqual(histogram.luma.count, HistogramData.binCount)
    }

    func testInfinitePixelDoesNotTrapTheStatsPass() {
        let buffer = pixels([Float.infinity, -Float.infinity, 0.5, 0.5,
                             0.5, 0.5, 0.5, 0.5,
                             0.5, 0.5, 0.5, 0.5,
                             0.5, 0.5, 0.5, 0.5])
        let (_, clipping) = HistogramCompute.compute(
            rgbaFloat: buffer, width: 4, height: 4, headroom: 4.0,
            highThreshold: 0.98, lowThreshold: 0.02)
        XCTAssertGreaterThanOrEqual(clipping.highR, 0)
    }

    /// +∞ is the top of the range and −∞ the bottom — a non-finite pixel is
    /// substituted, not discarded, so the histogram still describes 16 pixels.
    func testInfinitiesLandAtTheEndsOfTheRange() {
        let (histogram, _) = HistogramCompute.compute(
            rgbaFloat: pixels([Float]([Float.infinity] + Array(repeating: -Float.infinity, count: 15))),
            width: 4, height: 4, headroom: 1.0,
            highThreshold: 0.98, lowThreshold: 0.02)
        XCTAssertGreaterThan(histogram.luma[HistogramData.binCount - 1], 0,
                             "+∞ belongs in the top bin")
        XCTAssertGreaterThan(histogram.luma[0], 0, "−∞ belongs in the bottom bin")
    }

    // MARK: - The .cube importer

    private func cube(size: Int, values: [String]) -> String {
        (["LUT_3D_SIZE \(size)"] + values).joined(separator: "\n")
    }

    func testParserRefusesNaNValues() {
        var rows = [String](repeating: "0.5 0.5 0.5", count: 8)
        rows[3] = "0.5 nan 0.5"
        XCTAssertThrowsError(try CubeLUTParser.parse(cube(size: 2, values: rows))) { error in
            XCTAssertEqual(error as? CubeLUTParser.ParseError, .badValue(line: 5))
        }
    }

    /// `Float("1e40")` overflows to +∞ without failing, so a file need not
    /// literally say "inf" to smuggle one in.
    func testParserRefusesOverflowingLiterals() {
        var rows = [String](repeating: "0.5 0.5 0.5", count: 8)
        rows[0] = "1e40 0.5 0.5"
        XCTAssertThrowsError(try CubeLUTParser.parse(cube(size: 2, values: rows)))
    }

    func testParserRefusesNonFiniteDomain() {
        let text = (["LUT_3D_SIZE 2", "DOMAIN_MAX 1.0 nan 1.0"]
                    + [String](repeating: "0.5 0.5 0.5", count: 8)).joined(separator: "\n")
        XCTAssertThrowsError(try CubeLUTParser.parse(text))
    }

    func testAFiniteCubeStillParses() throws {
        let rows = [String](repeating: "0.5 0.5 0.5", count: 8)
        XCTAssertEqual(try CubeLUTParser.parse(cube(size: 2, values: rows)).lut.size, 2)
    }

    // MARK: - The restore boundary

    /// `edit_luts` rows from a `.muselibrary` are written by a plain INSERT and
    /// never see the importer. A NaN in that blob is refused at the render
    /// choke point, which makes the stack unrenderable — so the ORIGINAL
    /// renders, the same failure mode a missing row already produces.
    func testStoredCubeWithNaNIsRefusedByTheRegistry() throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        var floats = [Float](repeating: 0.5, count: 2 * 2 * 2 * 3)
        floats[7] = .nan
        let blob = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        try q.write { db in
            var row = EditLutRow(id: "nanlut", name: "Bad", size: 2, data: blob, created_at: 0)
            try row.insert(db)
        }
        XCTAssertNil(LutRegistry.rgbaCube(for: "nanlut", queue: q))
        LutRegistry.invalidate("nanlut")
    }

    func testStoredFiniteCubeIsStillServed() throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        let floats = [Float](repeating: 0.5, count: 2 * 2 * 2 * 3)
        let blob = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        try q.write { db in
            var row = EditLutRow(id: "goodlut", name: "Good", size: 2, data: blob, created_at: 0)
            try row.insert(db)
        }
        XCTAssertNotNil(LutRegistry.rgbaCube(for: "goodlut", queue: q))
        LutRegistry.invalidate("goodlut")
    }
}
