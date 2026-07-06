import XCTest
@testable import Muse

/// Pure ordering tests for the tag-chip sort modes (no DB).
final class TagChipLoaderOrderTests: XCTestCase {
    private let counts = ["zebra": 5, "apple": 5, "mango": 9]

    func testCountModeMostUsedFirstThenAlpha() {
        let out = TagChipLoader.ordered(counts, sortMode: .count).map(\.label)
        XCTAssertEqual(out, ["mango", "apple", "zebra"])   // 9, then 5&5 A→Z
    }

    func testAlphabeticalMode() {
        let out = TagChipLoader.ordered(counts, sortMode: .alphabetical).map(\.label)
        XCTAssertEqual(out, ["apple", "mango", "zebra"])
    }

    func testDefaultIsCount() {
        XCTAssertEqual(TagChipLoader.ordered(counts).map(\.label),
                       ["mango", "apple", "zebra"])
    }

    func testRatingsSortToFrontHighestFirst() {
        let c = ["beach": 9, "\u{2605}\u{2605}": 2, "\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}": 1, "apple": 3]
        let out = TagChipLoader.ordered(c, sortMode: .count).map(\.label)
        // Ratings first (5★ before 2★), then non-ratings by count (beach 9, apple 3).
        XCTAssertEqual(out, ["\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}", "\u{2605}\u{2605}", "beach", "apple"])
    }

    func testRatingsFrontEvenInAlphabeticalMode() {
        let c = ["zebra": 1, "\u{2605}": 4, "apple": 1]
        let out = TagChipLoader.ordered(c, sortMode: .alphabetical).map(\.label)
        XCTAssertEqual(out, ["\u{2605}", "apple", "zebra"])
    }
}
