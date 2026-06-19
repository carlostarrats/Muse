import XCTest
@testable import Muse

final class ImageLayoutTests: XCTestCase {

    func testAllCasesOrderMatchesWireframe() {
        XCTAssertEqual(ImageLayout.allCases.map(\.displayName),
                       ["Mason", "1:1", "9:16", "16:9",
                        "4:5", "5:4", "6:7", "7:6",
                        "2:3", "3:2", "3:4", "4:3"])
    }

    func testMasonryHasNoAspect() {
        XCTAssertNil(ImageLayout.masonry.aspect)
    }

    func testSquareAspectIsOne() {
        XCTAssertEqual(ImageLayout.r1x1.aspect, 1)
    }

    func testPortraitRatiosAreTallerThanWide() {
        // width:height with width < height → aspect (h/w) > 1.
        for layout in [ImageLayout.r9x16, .r4x5, .r6x7, .r2x3, .r3x4] {
            XCTAssertGreaterThan(layout.aspect ?? 0, 1, "\(layout) should be tall")
            XCTAssertEqual(layout.iconKind, .portrait)
        }
    }

    func testLandscapeRatiosAreWiderThanTall() {
        for layout in [ImageLayout.r16x9, .r5x4, .r7x6, .r3x2, .r4x3] {
            XCTAssertLessThan(layout.aspect ?? 99, 1, "\(layout) should be wide")
            XCTAssertEqual(layout.iconKind, .landscape)
        }
    }

    func testSpecificAspectValues() throws {
        XCTAssertEqual(try XCTUnwrap(ImageLayout.r9x16.aspect), 16.0 / 9, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(ImageLayout.r16x9.aspect), 9.0 / 16, accuracy: 0.0001)
    }

    func testIconKindForMasonAndSquare() {
        XCTAssertEqual(ImageLayout.masonry.iconKind, .mason)
        XCTAssertEqual(ImageLayout.r1x1.iconKind, .square)
    }

    func testResolveDefaultsToMasonry() {
        XCTAssertEqual(ImageLayout.resolve(nil), .masonry)
        XCTAssertEqual(ImageLayout.resolve("bogus"), .masonry)
        XCTAssertEqual(ImageLayout.resolve("r3x4"), .r3x4)
    }
}
