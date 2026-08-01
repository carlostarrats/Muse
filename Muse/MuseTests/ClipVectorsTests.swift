//
//  ClipVectorsTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

private func assertVectorsEqual(_ a: [Float], _ b: [Float], accuracy: Float,
                                file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) {
        XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line)
    }
}

final class ClipVectorsTests: XCTestCase {
    func testRoundTripWithinFloat16Tolerance() {
        let original: [Float] = (0..<512).map { Float($0) / 512.0 - 0.5 }
        let data = ClipVectors.toData(original)
        XCTAssertEqual(data.count, 512 * 2, "512 x Float16 LE = 1024 bytes")
        let back = ClipVectors.fromData(data)
        XCTAssertNotNil(back)
        assertVectorsEqual(original, back!, accuracy: 0.01)
    }

    func testOddLengthBlobReturnsNil() {
        XCTAssertNil(ClipVectors.fromData(Data(repeating: 0, count: 101)))
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(ClipVectors.fromData(Data()))
    }

    func testNormalizationSurvivesRoundTrip() {
        var v: [Float] = (0..<512).map { _ in Float.random(in: -1...1) }
        let norm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        v = v.map { $0 / norm }
        let back = ClipVectors.fromData(ClipVectors.toData(v))!
        let backNorm = (back.reduce(0) { $0 + $1 * $1 }).squareRoot()
        XCTAssertEqual(backNorm, 1.0, accuracy: 0.01)
    }
}

final class ClipCentroidTests: XCTestCase {
    func testSingleAnchorIdentity() {
        let v: [Float] = [0.6, 0.8] // already unit-length
        let centroid = ClipCentroid.centroid([v])
        XCTAssertNotNil(centroid)
        assertVectorsEqual(centroid!, v, accuracy: 0.001)
    }

    func testMeanThenRenormalize() {
        let centroid = ClipCentroid.centroid([[1, 0], [0, 1]])!
        XCTAssertEqual(centroid[0], centroid[1], accuracy: 0.001)
        let norm = (centroid.reduce(0) { $0 + $1 * $1 }).squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 0.001)
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(ClipCentroid.centroid([]))
    }

    func testMismatchedDimensionsAreSkipped() {
        // A vector from another model generation must never contribute.
        let centroid = ClipCentroid.centroid([[1, 0], [1, 0, 0]])!
        assertVectorsEqual(centroid, [1, 0], accuracy: 0.001)
    }
}

/// The wire format is IEEE-754 binary16 and the SAME bytes must come out of
/// either encoder — the hardware `Float16` path on Apple Silicon and the
/// portable bit-twiddle used on Intel. These bytes sit in the database and
/// travel in backups, so a vector written on one machine has to read back
/// identically on the other; a drift here silently corrupts every embedding
/// that crosses architectures.
///
/// On arm64 this compares the two implementations directly. On x86_64 the
/// portable path IS the implementation, so the round-trip assertions still
/// hold it to the format.
final class ClipVectorsPortabilityTests: XCTestCase {

    /// Every representable half, both directions.
    func testPortableAndHardwareAgreeOnEveryHalfBitPattern() {
        for raw in UInt16.min...UInt16.max {
            let portable = ClipVectors.portableFloat(fromHalfBits: raw)
            let live = ClipVectors.float(fromHalfBits: raw)
            if portable.isNaN {
                XCTAssertTrue(live.isNaN, "0x\(String(raw, radix: 16)) should decode to NaN")
            } else {
                XCTAssertEqual(portable.bitPattern, live.bitPattern,
                               "half 0x\(String(raw, radix: 16)) decoded differently")
            }
        }
    }

    /// Float → half across the whole exponent range, including the rounding
    /// boundaries, subnormals, overflow and the fp16 maximum.
    func testPortableAndHardwareAgreeOnEncoding() {
        var values: [Float] = [0, -0, 1, -1, 0.5, -0.5,
                               65504, -65504,        // fp16 max
                               65519.996,            // rounds to max
                               65520,                // rounds to infinity
                               6.103515625e-05,      // smallest normal
                               5.9604645e-08,        // smallest subnormal
                               1e-10, -1e-10,        // underflow
                               1e30, -1e30,          // overflow
                               .infinity, -.infinity]
        // A sweep of the exponent range plus rounding-tie candidates.
        for e in -30...30 {
            for m in stride(from: 1.0, to: 2.0, by: 0.013) {
                values.append(Float(m * pow(2.0, Double(e))))
                values.append(Float(-m * pow(2.0, Double(e))))
            }
        }
        for v in values {
            XCTAssertEqual(ClipVectors.portableHalfBits(v), ClipVectors.halfBits(v),
                           "encoding \(v) differed between implementations")
        }
    }

    func testNaNStaysNaNRatherThanBecomingInfinity() {
        let bits = ClipVectors.portableHalfBits(.nan)
        XCTAssertEqual(bits & 0x7C00, 0x7C00, "exponent must be all-ones")
        XCTAssertNotEqual(bits & 0x03FF, 0, "mantissa must be non-zero, or it is Infinity")
        XCTAssertTrue(ClipVectors.portableFloat(fromHalfBits: bits).isNaN)
    }

    /// Full pipeline through the public API, since that is what writes rows.
    func testBlobRoundTripIsBitIdenticalAcrossImplementations() {
        let vector: [Float] = (0..<512).map { Float(sin(Double($0))) }
        let data = ClipVectors.toData(vector)
        var portableData = Data(capacity: vector.count * 2)
        for value in vector {
            var half = ClipVectors.portableHalfBits(value).littleEndian
            withUnsafeBytes(of: &half) { portableData.append(contentsOf: $0) }
        }
        XCTAssertEqual(data, portableData, "the two encoders produced different bytes")
    }
}
