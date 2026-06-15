import XCTest
@testable import Muse

final class ColorTaggerTests: XCTestCase {
    // MARK: - Weighted (live analysis path)

    func testDominantOnlyWhenOthersAreTiny() {
        // An all-blue image with a sliver of white background: only "blue".
        let names = ColorTagger.tags(fromWeighted: [("#1a3fcc", 0.95), ("#ffffff", 0.05)])
        XCTAssertEqual(names, ["blue"])
    }

    func testTinyAccentIsDropped() {
        // A small red accent (5%) must not tag the whole image red.
        let names = ColorTagger.tags(fromWeighted: [("#ffffff", 0.70),
                                                     ("#000000", 0.20),
                                                     ("#ff0000", 0.05)])
        XCTAssertEqual(names, ["white", "black"])
    }

    func testMeaningfulSecondaryIsKept() {
        let names = ColorTagger.tags(fromWeighted: [("#ffffff", 0.55),
                                                    ("#ff0000", 0.45)])
        XCTAssertEqual(names, ["white", "red"])
    }

    func testNamesAreDeduped() {
        let names = ColorTagger.tags(fromWeighted: [("#0000ff", 0.50),
                                                    ("#1a3fcc", 0.40),
                                                    ("#ffffff", 0.10)])
        XCTAssertEqual(names, ["blue"])
    }

    func testCappedAtMax() {
        let names = ColorTagger.tags(fromWeighted: [("#ff0000", 0.25),
                                                    ("#00ff00", 0.25),
                                                    ("#0000ff", 0.25),
                                                    ("#ffff00", 0.25)], maxTags: 3)
        XCTAssertEqual(names.count, 3)
    }

    // MARK: - From stored palette (one-time recompute path)

    func testFromPaletteNamesDedupCap() {
        let names = ColorTagger.tags(fromPalette: ["#0000ff", "#ffffff", "#1a1a1a"])
        XCTAssertEqual(names, ["blue", "white", "black"])
    }

    func testFromPaletteDropsStaleReds() {
        // A brown/taupe palette (the IMG_0509 case) must not yield "red".
        let names = ColorTagger.tags(fromPalette: ["#927f74", "#bdad9b", "#615654",
                                                   "#2e2b32", "#e8e4d9"])
        XCTAssertFalse(names.contains("red"))
    }
}
