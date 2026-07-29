import XCTest
@testable import Muse

/// Two library roots pointing at the same folder produced two identical sidebar
/// rows that BOTH highlighted when either was clicked (the selected-row test
/// compares URLs). These pin which one survives.
final class RootDedupeTests: XCTestCase {

    func testKeepsTheFirstOfADuplicatePair() {
        XCTAssertEqual(RootDedupe.keepIndices(resolvedPaths: ["/a", "/b", "/a"]), [0, 1])
    }

    func testNoDuplicatesKeepsEverything() {
        XCTAssertEqual(RootDedupe.keepIndices(resolvedPaths: ["/a", "/b", "/c"]), [0, 1, 2])
    }

    func testEmptyIsEmpty() {
        XCTAssertEqual(RootDedupe.keepIndices(resolvedPaths: []), [])
    }

    /// Fail closed: a root whose bookmark can't resolve right now (unplugged
    /// volume, un-materialized iCloud container) must never be merged away.
    func testUnresolvedRootsAreAlwaysKept() {
        XCTAssertEqual(RootDedupe.keepIndices(resolvedPaths: [nil, nil, nil]), [0, 1, 2])
    }

    func testUnresolvedRootDoesNotCollideWithAResolvedOne() {
        XCTAssertEqual(RootDedupe.keepIndices(resolvedPaths: ["/a", nil, "/a", nil]), [0, 1, 3])
    }

    /// Three copies collapse to one, not two.
    func testCollapsesRunsOfMoreThanTwo() {
        XCTAssertEqual(RootDedupe.keepIndices(resolvedPaths: ["/a", "/a", "/a", "/b"]), [0, 3])
    }

    /// Order is preserved — the sidebar's manual ordering rides on it.
    func testKeptIndicesStayAscending() {
        let keep = RootDedupe.keepIndices(resolvedPaths: ["/c", "/a", "/c", "/b", "/a"])
        XCTAssertEqual(keep, keep.sorted())
        XCTAssertEqual(keep, [0, 1, 3])
    }
}
