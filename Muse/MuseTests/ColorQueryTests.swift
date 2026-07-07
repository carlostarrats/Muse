import XCTest
@testable import Muse

final class ColorQueryTests: XCTestCase {

    func testHashPrefixedHexIsColor() {
        let p = ColorQuery.parse("#3a7bd5")
        XCTAssertEqual(p.hexes.count, 1)
        XCTAssertEqual(p.textRemainder, "")
        // #3a7bd5 → (58, 123, 213)/255
        XCTAssertEqual(p.hexes[0].r, 58.0 / 255, accuracy: 0.001)
        XCTAssertEqual(p.hexes[0].g, 123.0 / 255, accuracy: 0.001)
        XCTAssertEqual(p.hexes[0].b, 213.0 / 255, accuracy: 0.001)
    }

    func testBareSixDigitHexIsColor() {
        let p = ColorQuery.parse("3a7bd5")
        XCTAssertEqual(p.hexes.count, 1)
        XCTAssertEqual(p.textRemainder, "")
    }

    func testThreeDigitShorthandExpands() {
        // #f0c → #ff00cc
        let p = ColorQuery.parse("#f0c")
        XCTAssertEqual(p.hexes.count, 1)
        XCTAssertEqual(p.hexes[0].r, 1.0, accuracy: 0.001)
        XCTAssertEqual(p.hexes[0].g, 0.0, accuracy: 0.001)
        XCTAssertEqual(p.hexes[0].b, 0xcc / 255.0, accuracy: 0.001)
    }

    func testInvalidHexFallsThroughToText() {
        // Too short, and a non-hex char — both stay text.
        let p = ColorQuery.parse("#12 #gggggg")
        XCTAssertTrue(p.hexes.isEmpty)
        XCTAssertEqual(p.textRemainder, "#12 #gggggg")
    }

    func testCommaSpaceSplittingMultiHex() {
        // The exact string the COLORS card writes to the clipboard.
        let p = ColorQuery.parse("#3a7bd5, #f0e0c0, #202020")
        XCTAssertEqual(p.hexes.count, 3)
        XCTAssertEqual(p.textRemainder, "")
    }

    func testMixedHexAndTextSplits() {
        let p = ColorQuery.parse("red #f0e0c0")
        XCTAssertEqual(p.hexes.count, 1)
        XCTAssertEqual(p.textRemainder, "red")
    }

    func testTextRemainderPreservesOrder() {
        let p = ColorQuery.parse("white #202020 wedding dress")
        XCTAssertEqual(p.hexes.count, 1)
        XCTAssertEqual(p.textRemainder, "white wedding dress")
    }

    func testPlainTextHasNoHexes() {
        let p = ColorQuery.parse("red blue")
        XCTAssertTrue(p.hexes.isEmpty)
        XCTAssertEqual(p.textRemainder, "red blue")
    }

    func testCaseInsensitiveHex() {
        let p = ColorQuery.parse("#3A7BD5")
        XCTAssertEqual(p.hexes.count, 1)
        XCTAssertEqual(p.textRemainder, "")
    }
}
