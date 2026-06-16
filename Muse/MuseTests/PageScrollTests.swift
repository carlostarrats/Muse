import XCTest
import CoreGraphics
@testable import Muse

final class PageScrollTests: XCTestCase {
    // viewport 800, document 5000 → step = 800 - min(40, 96) = 760; maxY = 4200.
    func testPageDownFromTop() {
        let y = PageScroll.newOriginY(currentY: 0, viewportHeight: 800,
                                      documentHeight: 5000, pageUp: false)
        XCTAssertEqual(y, 760, accuracy: 0.5)
    }

    func testPageUpFromTopClampsToZero() {
        let y = PageScroll.newOriginY(currentY: 0, viewportHeight: 800,
                                      documentHeight: 5000, pageUp: true)
        XCTAssertEqual(y, 0, accuracy: 0.5)
    }

    func testPageDownNearBottomClampsToMax() {
        let y = PageScroll.newOriginY(currentY: 4100, viewportHeight: 800,
                                      documentHeight: 5000, pageUp: false)
        XCTAssertEqual(y, 4200, accuracy: 0.5)   // maxY = 5000 - 800
    }

    func testPageUpFromMiddle() {
        let y = PageScroll.newOriginY(currentY: 2000, viewportHeight: 800,
                                      documentHeight: 5000, pageUp: true)
        XCTAssertEqual(y, 1240, accuracy: 0.5)   // 2000 - 760
    }

    func testDocumentShorterThanViewportStaysAtZero() {
        let down = PageScroll.newOriginY(currentY: 0, viewportHeight: 800,
                                         documentHeight: 500, pageUp: false)
        XCTAssertEqual(down, 0, accuracy: 0.5)
        let up = PageScroll.newOriginY(currentY: 0, viewportHeight: 800,
                                       documentHeight: 500, pageUp: true)
        XCTAssertEqual(up, 0, accuracy: 0.5)
    }

    func testOverlapCappedForShortViewport() {
        // viewport 200 → overlap = min(40, 24) = 24; step = 176.
        let y = PageScroll.newOriginY(currentY: 0, viewportHeight: 200,
                                      documentHeight: 5000, pageUp: false)
        XCTAssertEqual(y, 176, accuracy: 0.5)
    }
}
