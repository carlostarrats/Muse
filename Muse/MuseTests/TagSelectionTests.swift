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

}
