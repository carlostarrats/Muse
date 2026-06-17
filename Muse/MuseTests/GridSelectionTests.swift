import XCTest
@testable import Muse

final class GridSelectionTests: XCTestCase {
    let order = ["a", "b", "c", "d", "e"]   // grid order (paths)

    func testSingleReplaces() {
        let r = GridSelection.apply(.single("c"), to: ["a", "b"], anchor: nil, order: order)
        XCTAssertEqual(r.selection, ["c"])
        XCTAssertEqual(r.anchor, "c")
    }

    func testToggleAddsAndRemoves() {
        var r = GridSelection.apply(.toggle("c"), to: ["a"], anchor: "a", order: order)
        XCTAssertEqual(r.selection, ["a", "c"]); XCTAssertEqual(r.anchor, "c")
        r = GridSelection.apply(.toggle("a"), to: r.selection, anchor: r.anchor, order: order)
        XCTAssertEqual(r.selection, ["c"])
    }

    func testRangeFromAnchorInclusive() {
        let r = GridSelection.apply(.range("d"), to: ["b"], anchor: "b", order: order)
        XCTAssertEqual(r.selection, ["b", "c", "d"])   // b..d
        XCTAssertEqual(r.anchor, "b")                  // anchor unchanged by range
    }

    func testRangeBackwards() {
        let r = GridSelection.apply(.range("a"), to: ["d"], anchor: "d", order: order)
        XCTAssertEqual(r.selection, ["a", "b", "c", "d"])
    }

    func testRangeWithoutAnchorActsAsSingle() {
        let r = GridSelection.apply(.range("c"), to: [], anchor: nil, order: order)
        XCTAssertEqual(r.selection, ["c"]); XCTAssertEqual(r.anchor, "c")
    }
}
