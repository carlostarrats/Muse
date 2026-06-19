import XCTest
@testable import Muse

final class CollectionSortTests: XCTestCase {
    private func item(_ name: String, created: Int64 = 0, updated: Int64 = 0) -> CollectionSort.Item {
        CollectionSort.Item(id: name, name: name, createdAt: created, updatedAt: updated)
    }

    func testCollectionCasesAreOnlyTheApplicableModes() {
        XCTAssertEqual(SortMode.collectionCases, [.name, .dateCreated, .dateModified])
    }

    func testNameAscendingLocalizedNumeric() {
        let items = [item("Banana"), item("apple"), item("Cherry"), item("file10"), item("file2")]
        XCTAssertEqual(CollectionSort.order(items, by: .name, reversed: false),
                       ["apple", "Banana", "Cherry", "file2", "file10"])
    }

    func testNameReversed() {
        let items = [item("a"), item("b"), item("c")]
        XCTAssertEqual(CollectionSort.order(items, by: .name, reversed: true),
                       ["c", "b", "a"])
    }

    func testDateCreatedNewestFirst() {
        let items = [item("old", created: 100), item("new", created: 300), item("mid", created: 200)]
        XCTAssertEqual(CollectionSort.order(items, by: .dateCreated, reversed: false),
                       ["new", "mid", "old"])
    }

    func testDateModifiedNewestFirstReversedIsOldestFirst() {
        let items = [item("old", updated: 100), item("new", updated: 300), item("mid", updated: 200)]
        XCTAssertEqual(CollectionSort.order(items, by: .dateModified, reversed: true),
                       ["old", "mid", "new"])
    }

    func testEqualDatesTiebreakByName() {
        let items = [item("b", created: 100), item("a", created: 100)]
        XCTAssertEqual(CollectionSort.order(items, by: .dateCreated, reversed: false),
                       ["a", "b"])
    }
}
