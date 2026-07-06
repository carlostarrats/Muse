import XCTest
import CoreGraphics
@testable import Muse

final class GridScrollRevealTests: XCTestCase {

    // Viewport 500 tall, document 2000 tall → maxY = 1500. margin 20.

    func testAlreadyVisibleTileDoesNotScroll() {
        // Tile top 100, height 80 → sits within [20, 480]. No change.
        let y = GridScrollReveal.newOriginY(
            clipOriginY: 300, viewportHeight: 500, documentHeight: 2000,
            tileTopInViewport: 100, tileHeight: 80, margin: 20)
        XCTAssertEqual(y, 300, accuracy: 0.001)
    }

    func testTileBelowScrollsDownSoBottomLandsAtViewportMinusMargin() {
        // Tile top 460, height 80 → bottom 540 > 480. Δ = 540 - 480 = 60.
        let y = GridScrollReveal.newOriginY(
            clipOriginY: 300, viewportHeight: 500, documentHeight: 2000,
            tileTopInViewport: 460, tileHeight: 80, margin: 20)
        XCTAssertEqual(y, 360, accuracy: 0.001)
    }

    func testTileAboveScrollsUpSoTopLandsAtMargin() {
        // Tile top -50 (above viewport). Δ = -50 - 20 = -70.
        let y = GridScrollReveal.newOriginY(
            clipOriginY: 300, viewportHeight: 500, documentHeight: 2000,
            tileTopInViewport: -50, tileHeight: 80, margin: 20)
        XCTAssertEqual(y, 230, accuracy: 0.001)
    }

    func testClampsToZeroAtTop() {
        // Small upward need but already near the very top → clamp at 0.
        let y = GridScrollReveal.newOriginY(
            clipOriginY: 10, viewportHeight: 500, documentHeight: 2000,
            tileTopInViewport: -50, tileHeight: 80, margin: 20)
        // raw = 10 + (-50 - 20) = -60 → clamped to 0.
        XCTAssertEqual(y, 0, accuracy: 0.001)
    }

    func testClampsToMaxYAtBottom() {
        // Near the bottom; requested scroll exceeds maxY 1500 → clamp.
        let y = GridScrollReveal.newOriginY(
            clipOriginY: 1490, viewportHeight: 500, documentHeight: 2000,
            tileTopInViewport: 470, tileHeight: 80, margin: 20)
        // bottom 550 > 480 → raw = 1490 + (550 - 480) = 1560 → clamp to 1500.
        XCTAssertEqual(y, 1500, accuracy: 0.001)
    }

    func testOversizedTilePinsTopNotBottom() {
        // Tile taller than the viewport: top branch wins, top → margin.
        let y = GridScrollReveal.newOriginY(
            clipOriginY: 300, viewportHeight: 500, documentHeight: 3000,
            tileTopInViewport: -30, tileHeight: 700, margin: 20)
        // top -30 < 20 → raw = 300 + (-30 - 20) = 250.
        XCTAssertEqual(y, 250, accuracy: 0.001)
    }
}
