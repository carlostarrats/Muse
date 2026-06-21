import XCTest
@testable import Muse

final class HeroPaletteTests: XCTestCase {
    /// `count` RGBA pixels of one solid color (opaque).
    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count * 4)
        for _ in 0..<count { out.append(contentsOf: [r, g, b, 255]) }
        return out
    }

    func testSolidColorYieldsThatColor() {
        let bytes = solid(255, 0, 0, count: 16)   // 4×4 red
        XCTAssertEqual(HeroPalette.paletteHexes(fromRGBA: bytes, width: 4, height: 4),
                       ["#ff0000"])
    }

    func testTwoRegionsYieldBothDarkToLight() {
        // 4×4 = 16 px: 8 black + 8 white. Distinct buckets, ordered dark → light.
        let bytes = solid(0, 0, 0, count: 8) + solid(255, 255, 255, count: 8)
        XCTAssertEqual(HeroPalette.paletteHexes(fromRGBA: bytes, width: 4, height: 4),
                       ["#000000", "#ffffff"])
    }

    func testEmptyDimensionsYieldNothing() {
        XCTAssertEqual(HeroPalette.paletteHexes(fromRGBA: [], width: 0, height: 0), [])
    }

    func testShortBufferYieldsNothing() {
        // Claims 4×4 (needs 64 bytes) but provides only 8.
        let bytes = solid(10, 20, 30, count: 2)
        XCTAssertEqual(HeroPalette.paletteHexes(fromRGBA: bytes, width: 4, height: 4), [])
    }
}
