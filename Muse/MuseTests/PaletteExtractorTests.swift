import XCTest
@testable import Muse

final class PaletteExtractorTests: XCTestCase {
    func testTwoObviousClusters() {
        // 60 red-ish, 40 blue-ish pixels
        var px: [(Double, Double, Double)] = []
        for i in 0..<60 { px.append((0.9 + Double(i % 3) * 0.02, 0.05, 0.05)) }
        for i in 0..<40 { px.append((0.05, 0.05, 0.9 + Double(i % 3) * 0.02)) }
        let palette = PaletteExtractor.kmeansHex(pixels: px, k: 2, seed: 42)
        XCTAssertEqual(palette.count, 2)
        XCTAssertTrue(palette[0].hasPrefix("#e") || palette[0].hasPrefix("#f"),
                      "expected red-dominant first, got \(palette)")
    }
    func testCapsAtSix() {
        var px: [(Double, Double, Double)] = []
        for i in 0..<300 {
            px.append((Double(i % 10) / 10, Double((i / 10) % 10) / 10, Double(i % 7) / 7))
        }
        let palette = PaletteExtractor.kmeansHex(pixels: px, k: 9, seed: 1)
        XCTAssertLessThanOrEqual(palette.count, 6)
    }
}
