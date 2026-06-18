import XCTest
@testable import Muse

final class SelectionStyleTests: XCTestCase {
    private func rgb(_ r: Double, _ g: Double, _ b: Double) -> MoodRGB {
        MoodRGB(r: r, g: g, b: b)
    }

    // Neutral backgrounds (Light/Dark/Auto + near-grey Custom) → blue.
    func testNeutralBackgroundsUseSystemBlue() {
        XCTAssertEqual(SelectionStyle.accent(forBackground: rgb(0, 0, 0)), .systemBlue)
        XCTAssertEqual(SelectionStyle.accent(forBackground: rgb(1, 1, 1)), .systemBlue)
        XCTAssertEqual(SelectionStyle.accent(forBackground: rgb(0.5, 0.5, 0.5)), .systemBlue)
        // The shipped Light/Dark mood backgrounds.
        XCTAssertEqual(SelectionStyle.accent(forBackground: rgb(0.965, 0.962, 0.955)), .systemBlue)
        XCTAssertEqual(SelectionStyle.accent(forBackground: rgb(0.066, 0.066, 0.078)), .systemBlue)
        // A barely-tinted Custom near grey stays neutral.
        XCTAssertEqual(SelectionStyle.accent(forBackground: rgb(0.50, 0.48, 0.46)), .systemBlue)
    }

    // A light, colorful background → black ring (black contrasts better).
    func testLightColorfulBackgroundUsesBlack() {
        let bg = rgb(0.6, 0.9, 0.6) // light green
        XCTAssertEqual(SelectionStyle.accent(forBackground: bg), .black)
    }

    // A dark, colorful background → white ring (white contrasts better).
    func testDarkColorfulBackgroundUsesWhite() {
        let bg = rgb(0.3, 0.0, 0.4) // dark purple
        XCTAssertEqual(SelectionStyle.accent(forBackground: bg), .white)
    }

    // The saturation gate is a hard cliff at colorfulSaturationThreshold.
    // Just below it stays neutral (blue); at/above it goes colorful (black/white).
    func testSaturationThresholdBoundary() {
        // saturation = (max - min) / max. With max = 1.0:
        //   min 0.81 → sat 0.19 (< 0.20) → neutral → blue
        //   min 0.79 → sat 0.21 (>= 0.20) → colorful → black/white
        XCTAssertLessThan(SelectionStyle.saturation(rgb(1.0, 0.9, 0.81)),
                          SelectionStyle.colorfulSaturationThreshold)
        XCTAssertEqual(SelectionStyle.accent(forBackground: rgb(1.0, 0.9, 0.81)), .systemBlue)

        XCTAssertGreaterThanOrEqual(SelectionStyle.saturation(rgb(1.0, 0.9, 0.79)),
                                    SelectionStyle.colorfulSaturationThreshold)
        XCTAssertNotEqual(SelectionStyle.accent(forBackground: rgb(1.0, 0.9, 0.79)), .systemBlue)
    }

    // The chosen ring always clears WCAG AA (>= 4.5:1) on colorful backgrounds,
    // including the luminance extremes (very dark + very bright saturated hues).
    func testChosenAccentClearsAAOnColorfulBackgrounds() {
        let colorful = [rgb(0.6, 0.9, 0.6), rgb(0.3, 0.0, 0.4),
                        rgb(0.0, 0.5, 0.5), rgb(0.9, 0.2, 0.2),
                        rgb(0.2, 0.2, 0.9), rgb(0.95, 0.85, 0.1),
                        rgb(0.0, 0.0, 0.6), rgb(1.0, 1.0, 0.0)]
        for bg in colorful {
            let bgL = SelectionStyle.relativeLuminance(bg)
            let chosenL: Double
            switch SelectionStyle.accent(forBackground: bg) {
            case .white: chosenL = 1.0
            case .black: chosenL = 0.0
            case .systemBlue: XCTFail("expected black/white for \(bg)"); continue
            }
            XCTAssertGreaterThanOrEqual(
                SelectionStyle.contrast(chosenL, bgL), 4.5,
                "ring must clear AA against \(bg)")
        }
    }

    func testSaturationBasics() {
        XCTAssertEqual(SelectionStyle.saturation(rgb(0, 0, 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(SelectionStyle.saturation(rgb(0.5, 0.5, 0.5)), 0, accuracy: 1e-9)
        XCTAssertEqual(SelectionStyle.saturation(rgb(1, 0, 0)), 1, accuracy: 1e-9)
    }
}
