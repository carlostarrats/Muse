import XCTest
import CoreGraphics
@testable import Muse

final class CollectionsGridLayoutTests: XCTestCase {

    private let columns = 4
    private let gap: CGFloat = 24
    private let minInset: CGFloat = 14
    private let aspect: CGFloat = 0.9
    private let bleed: CGFloat = 9

    private func solve(_ width: CGFloat) -> CollectionsGridLayout.Result {
        CollectionsGridLayout.solve(width: width,
                                    columns: columns,
                                    gap: gap,
                                    minInset: minInset,
                                    coverAspect: aspect,
                                    shadowBleed: bleed)
    }

    /// The row still fills the viewport exactly: 2 insets + n cards + gaps.
    func testRowFillsWidth() {
        for w in stride(from: CGFloat(600), through: 2400, by: 137) {
            let r = solve(w)
            let total = r.inset * 2
                + r.cardWidth * CGFloat(columns)
                + gap * CGFloat(columns - 1)
            XCTAssertEqual(total, w, accuracy: 0.001, "width \(w)")
        }
    }

    /// The whole point: a fanned pile in the outer column never crosses the
    /// page bounds (shadow bleed included).
    func testFanStaysInsideBounds() {
        for w in stride(from: CGFloat(600), through: 2400, by: 137) {
            let r = solve(w)
            let cell = CGSize(width: r.cardWidth, height: r.cardWidth * aspect)
            let overhang = StackScatter.maxFanHalfWidth(cell: cell) - r.cardWidth / 2
            XCTAssertLessThanOrEqual(overhang + bleed, r.inset + 0.001, "width \(w)")
        }
    }

    /// The gutter never drops below the page's minimum.
    func testInsetNeverBelowMinimum() {
        for w in stride(from: CGFloat(200), through: 2400, by: 91) {
            XCTAssertGreaterThanOrEqual(solve(w).inset, minInset, "width \(w)")
        }
    }

    /// A cell too narrow for the fan to overhang falls back to the minimum
    /// inset rather than inventing a gutter.
    func testTallCellNeedsNoExtraGutter() {
        // coverAspect small → short side is tiny → fan travel is tiny.
        let r = CollectionsGridLayout.solve(width: 1200,
                                            columns: columns,
                                            gap: gap,
                                            minInset: minInset,
                                            coverAspect: 0.1,
                                            shadowBleed: 0)
        XCTAssertEqual(r.inset, minInset, accuracy: 0.001)
    }

    /// Degenerate widths stay non-negative rather than producing negative
    /// frames.
    func testDegenerateWidth() {
        let r = solve(0)
        XCTAssertGreaterThanOrEqual(r.cardWidth, 0)
        XCTAssertGreaterThanOrEqual(r.inset, minInset)
    }
}
