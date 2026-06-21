import XCTest
@testable import Muse

final class TagSelectionTests: XCTestCase {

    // MARK: - toggling

    func testToggleAddsAbsentLabelAtEnd() {
        XCTAssertEqual(TagSelection.toggling(["blue"], "screenshot"),
                       ["blue", "screenshot"])
    }

    func testToggleRemovesPresentLabel() {
        XCTAssertEqual(TagSelection.toggling(["blue", "screenshot"], "blue"),
                       ["screenshot"])
    }

    func testToggleRemovingSoleLabelEmptiesSelection() {
        XCTAssertEqual(TagSelection.toggling(["blue"], "blue"), [])
    }

    func testTogglePreservesInsertionOrder() {
        var sel: [String] = []
        sel = TagSelection.toggling(sel, "c")
        sel = TagSelection.toggling(sel, "a")
        sel = TagSelection.toggling(sel, "b")
        XCTAssertEqual(sel, ["c", "a", "b"])
    }

    // MARK: - bannerText (Oxford "and")

    func testNoBannerForZeroLabels() {
        XCTAssertNil(TagSelection.bannerText(for: []))
    }

    func testNoBannerForOneLabel() {
        XCTAssertNil(TagSelection.bannerText(for: ["blue"]))
    }

    func testBannerForTwoLabels() {
        XCTAssertEqual(TagSelection.bannerText(for: ["blue", "screenshot"]),
                       "Viewing blue and screenshot")
    }

    func testBannerForThreeLabelsUsesOxfordAnd() {
        XCTAssertEqual(
            TagSelection.bannerText(for: ["blue", "screenshot", "invoice"]),
            "Viewing blue, screenshot, and invoice")
    }

    func testBannerForFourLabels() {
        XCTAssertEqual(
            TagSelection.bannerText(for: ["a", "b", "c", "d"]),
            "Viewing a, b, c, and d")
    }
}
