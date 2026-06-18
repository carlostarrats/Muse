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
}
