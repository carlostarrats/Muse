//
//  SidebarCollectionSortTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class SidebarCollectionSortTests: XCTestCase {
    private func item(_ id: String, _ name: String, created: Int64, updated: Int64, order: Int)
        -> SidebarCollectionSort.Item {
        .init(id: id, name: name, createdAt: created, updatedAt: updated, sortOrder: order)
    }

    func testManualUsesSortOrderAscending() {
        let items = [
            item("a", "Zeta", created: 1, updated: 1, order: 2),
            item("b", "Alpha", created: 2, updated: 2, order: 0),
            item("c", "Mid", created: 3, updated: 3, order: 1),
        ]
        XCTAssertEqual(SidebarCollectionSort.order(items, by: .manual), ["b", "c", "a"])
    }

    func testNameIsAToZLocalized() {
        let items = [
            item("a", "banana", created: 1, updated: 1, order: 0),
            item("b", "Apple", created: 2, updated: 2, order: 1),
            item("c", "cherry", created: 3, updated: 3, order: 2),
        ]
        XCTAssertEqual(SidebarCollectionSort.order(items, by: .name), ["b", "a", "c"])
    }

    func testDateCreatedNewestFirstWithNameTie() {
        let items = [
            item("a", "Older", created: 10, updated: 1, order: 0),
            item("b", "Newer", created: 20, updated: 1, order: 1),
            item("c", "Bravo", created: 20, updated: 1, order: 2),  // tie w/ b on created
        ]
        // 20s first, name tiebreak Bravo < Newer; then Older
        XCTAssertEqual(SidebarCollectionSort.order(items, by: .dateCreated), ["c", "b", "a"])
    }

    func testDateModifiedNewestFirst() {
        let items = [
            item("a", "A", created: 1, updated: 5, order: 0),
            item("b", "B", created: 1, updated: 9, order: 1),
        ]
        XCTAssertEqual(SidebarCollectionSort.order(items, by: .dateModified), ["b", "a"])
    }
}
