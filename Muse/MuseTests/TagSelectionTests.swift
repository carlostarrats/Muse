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

    // MARK: - removing (per-pill ✕ in the active-filter bar)

    func testRemovingDropsTheLabel() {
        XCTAssertEqual(TagSelection.removing(["blue", "screenshot"], "blue"),
                       ["screenshot"])
    }

    func testRemovingSoleLabelEmptiesSelection() {
        XCTAssertEqual(TagSelection.removing(["blue"], "blue"), [])
    }

    func testRemovingAbsentLabelIsNoOp() {
        XCTAssertEqual(TagSelection.removing(["blue", "screenshot"], "navy"),
                       ["blue", "screenshot"])
    }

    func testRemovingPreservesOrderOfSurvivors() {
        XCTAssertEqual(TagSelection.removing(["a", "b", "c"], "b"),
                       ["a", "c"])
    }

    // MARK: - renaming (rename a selected tag, merge on collision)

    func testRenameRemapsSelectedLabel() {
        XCTAssertEqual(
            TagSelection.renaming(["blue", "screenshot"], from: "blue", to: "navy"),
            ["navy", "screenshot"])
    }

    func testRenameOntoAnotherSelectedLabelDeduplicates() {
        // TagStore merges on collision — renaming "a" to "b" while "b" is also
        // selected must not yield ["b","b"] (which would read "Viewing b and b").
        XCTAssertEqual(
            TagSelection.renaming(["a", "b"], from: "a", to: "b"),
            ["b"])
    }

    func testRenamePreservesOrderAfterDedup() {
        XCTAssertEqual(
            TagSelection.renaming(["a", "b", "c"], from: "c", to: "a"),
            ["a", "b"])
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

    // MARK: - bannerSegments (pill rendering)

    func testNoSegmentsForZeroOrOneLabel() {
        XCTAssertTrue(TagSelection.bannerSegments(for: []).isEmpty)
        XCTAssertTrue(TagSelection.bannerSegments(for: ["blue"]).isEmpty)
    }

    func testSegmentsForTwoLabels() {
        // "Viewing [blue] and [black]" — no commas, "and" before the last.
        XCTAssertEqual(
            TagSelection.bannerSegments(for: ["blue", "black"]),
            [
                .init(label: "blue", precededByAnd: false, trailingComma: false),
                .init(label: "black", precededByAnd: true, trailingComma: false),
            ])
    }

    func testSegmentsForThreeLabelsUseOxfordCommas() {
        // "Viewing [a], [b], and [c]" — commas hug every non-last pill, "and"
        // before the last.
        XCTAssertEqual(
            TagSelection.bannerSegments(for: ["a", "b", "c"]),
            [
                .init(label: "a", precededByAnd: false, trailingComma: true),
                .init(label: "b", precededByAnd: false, trailingComma: true),
                .init(label: "c", precededByAnd: true, trailingComma: false),
            ])
    }

    // MARK: - bannerText connective localization

    func testBannerTextUsesProvidedConnectives() {
        // The view passes localized connective words so the VoiceOver banner
        // reads in the user's language.
        XCTAssertEqual(
            TagSelection.bannerText(for: ["plage", "chien"], viewing: "Affichage", and: "et"),
            "Affichage plage et chien")
    }

    func testBannerTextDefaultsRemainEnglish() {
        XCTAssertEqual(
            TagSelection.bannerText(for: ["blue", "screenshot"]),
            "Viewing blue and screenshot")
    }

    func testBannerTextThreeLabelsWithLocalizedConnectives() {
        XCTAssertEqual(
            TagSelection.bannerText(for: ["a", "b", "c"], viewing: "Affichage", and: "et"),
            "Affichage a, b, et c")
    }
}
