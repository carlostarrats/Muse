import XCTest
@testable import Muse

final class CollectionIdentityTests: XCTestCase {
    func testGrownClusterKeepsID() {
        let old = ["c1": Set(["a", "b", "c", "d"])]
        let new = [Set(["a", "b", "c", "d", "e", "f"])]
        let matched = CollectionIdentity.match(old: old, new: new)
        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched[0].id, "c1")
        XCTAssertEqual(matched[0].members, Set(["a", "b", "c", "d", "e", "f"]))
        XCTAssertFalse(matched[0].isNew)
    }
    func testUnrelatedClusterGetsNewID() {
        let old = ["c1": Set(["a", "b", "c", "d"])]
        let new = [Set(["x", "y", "z", "w"])]
        let matched = CollectionIdentity.match(old: old, new: new)
        XCTAssertEqual(matched.count, 1)
        XCTAssertNotEqual(matched[0].id, "c1")
        XCTAssertTrue(matched[0].isNew)
    }
    func testMergePicksBestOverlap() {
        let old = ["c1": Set(["a", "b", "c", "d"]), "c2": Set(["e", "f", "g", "h"])]
        let new = [Set(["a", "b", "c", "d", "e", "f", "g", "h"])]
        let matched = CollectionIdentity.match(old: old, new: new)
        XCTAssertEqual(matched.count, 1)
        XCTAssertTrue(["c1", "c2"].contains(matched[0].id))
    }
}
