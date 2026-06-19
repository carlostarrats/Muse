import XCTest
@testable import Muse

final class TileBackgroundTests: XCTestCase {

    func testDisplayNames() {
        XCTAssertEqual(TileBackground.allCases.map(\.displayName),
                       ["None", "Auto", "Light", "Dark Grey", "Black"])
    }

    func testResolveDefaultsToAuto() {
        XCTAssertEqual(TileBackground.resolve(nil), .auto)
        XCTAssertEqual(TileBackground.resolve("bogus"), .auto)
        XCTAssertEqual(TileBackground.resolve("black"), .black)
    }

    func testNoneIsTransparent() {
        XCTAssertNil(TileBackground.none.backdropRGB(for: Mood.paperPalette))
    }

    func testAutoFollowsMoodTile() {
        XCTAssertEqual(TileBackground.auto.backdropRGB(for: Mood.paperPalette),
                       Mood.paperPalette.tileRGB)
        XCTAssertEqual(TileBackground.auto.backdropRGB(for: Mood.fallbackPalette),
                       Mood.fallbackPalette.tileRGB)
    }

    func testStaticValuesAreFixedAndIgnoreMood() {
        XCTAssertEqual(TileBackground.light.backdropRGB(for: Mood.fallbackPalette),
                       MoodRGB(r: 0.980, g: 0.980, b: 0.980))
        XCTAssertEqual(TileBackground.darkGrey.backdropRGB(for: Mood.paperPalette),
                       MoodRGB(r: 0.333, g: 0.333, b: 0.333))
        XCTAssertEqual(TileBackground.black.backdropRGB(for: Mood.paperPalette),
                       MoodRGB(r: 0.051, g: 0.051, b: 0.051))
    }
}
