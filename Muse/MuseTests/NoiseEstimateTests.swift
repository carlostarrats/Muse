import XCTest
import CoreGraphics
@testable import Muse

final class NoiseEstimateTests: XCTestCase {

    private func image(side: Int, value: (Int, Int) -> UInt8) -> CGImage {
        let bytesPerRow = side * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * side)
        for y in 0..<side {
            for x in 0..<side {
                let v = value(x, y)
                let i = (y * side + x) * 4
                data[i] = v; data[i + 1] = v; data[i + 2] = v; data[i + 3] = 255
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        return data.withUnsafeMutableBytes { raw -> CGImage in
            let ctx = CGContext(data: raw.baseAddress, width: side, height: side,
                                bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: cs,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            return ctx.makeImage()!
        }
    }

    private func noisyFlat(side: Int, amplitude: UInt8, seed: UInt64 = 42) -> CGImage {
        var generator = SplitMix64(seed: seed)
        return image(side: side) { _, _ in
            guard amplitude > 0 else { return 128 }
            let noise = Int(generator.next() % UInt64(amplitude * 2 + 1)) - Int(amplitude)
            return UInt8(min(max(128 + noise, 0), 255))
        }
    }

    private func flatClean(side: Int) -> CGImage { noisyFlat(side: side, amplitude: 0) }

    private func checkerboard(side: Int, cell: Int) -> CGImage {
        image(side: side) { x, y in ((x / cell) + (y / cell)) % 2 == 0 ? 40 : 220 }
    }

    func testFlatCleanImageHasNearZeroSigma() throws {
        let sigma = try XCTUnwrap(NoiseEstimate.sigma(flatClean(side: 128)))
        XCTAssertLessThan(sigma, 0.5)
    }

    func testNoisyFlatImageHasElevatedSigma() throws {
        let clean = try XCTUnwrap(NoiseEstimate.sigma(flatClean(side: 128)))
        let noisy = try XCTUnwrap(NoiseEstimate.sigma(noisyFlat(side: 128, amplitude: 30)))
        XCTAssertGreaterThan(noisy, clean + 2)
    }

    /// The flat-tile restriction IS the algorithm: a busy but clean
    /// checkerboard must not read as noisier than an actually noisy flat field.
    func testNoisyFlatScoresAboveTexturedButCleanCheckerboard() throws {
        let noisyFlatSigma = try XCTUnwrap(NoiseEstimate.sigma(noisyFlat(side: 128, amplitude: 25)))
        let checkerSigma = try XCTUnwrap(NoiseEstimate.sigma(checkerboard(side: 128, cell: 8)))
        XCTAssertGreaterThan(noisyFlatSigma, checkerSigma)
    }

    /// Normalization: a 4× larger source of the same scene must not read as
    /// proportionally noisier, or the score would depend on camera resolution.
    func testResolutionNormalizationKeepsBothScalesInTheSameBand() throws {
        let base = try XCTUnwrap(NoiseEstimate.sigma(noisyFlat(side: 256, amplitude: 20)))
        let scaled = try XCTUnwrap(NoiseEstimate.sigma(noisyFlat(side: 1024, amplitude: 20)))
        XCTAssertEqual(base, scaled, accuracy: max(base, scaled) * 0.6)
    }

    func testDegenerateTinyImageReturnsNil() {
        XCTAssertNil(NoiseEstimate.sigma(flatClean(side: 32)))
    }
}

/// Deterministic PRNG so a fixture can't flake.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
