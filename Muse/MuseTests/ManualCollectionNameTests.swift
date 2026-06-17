//
//  ManualCollectionNameTests.swift
//  MuseTests
//
//  Auto-naming for hand-made collections: "Collection 1", "Collection 2", …
//

import XCTest
@testable import Muse

final class ManualCollectionNameTests: XCTestCase {
    func testFirstIsCollection1() {
        XCTAssertEqual(ManualCollectionName.next(existing: []), "Collection 1")
        XCTAssertEqual(ManualCollectionName.next(existing: ["Vacation", "Recipes"]), "Collection 1")
    }

    func testIncrementsPastHighest() {
        XCTAssertEqual(ManualCollectionName.next(existing: ["Collection 1"]), "Collection 2")
        XCTAssertEqual(
            ManualCollectionName.next(existing: ["Collection 1", "Collection 2"]),
            "Collection 3")
    }

    func testGapsIgnoredUsesMaxPlusOne() {
        // Renamed/deleted middles shouldn't reuse a number → one past the max.
        XCTAssertEqual(ManualCollectionName.next(existing: ["Collection 3"]), "Collection 4")
        XCTAssertEqual(
            ManualCollectionName.next(existing: ["Collection 1", "Collection 5"]),
            "Collection 6")
    }

    func testRenamedCollectionsDontCount() {
        XCTAssertEqual(
            ManualCollectionName.next(existing: ["Beach", "Collection 2", "Work"]),
            "Collection 3")
    }

    func testNumberParsingIsStrict() {
        XCTAssertEqual(ManualCollectionName.number(in: "Collection 7"), 7)
        XCTAssertNil(ManualCollectionName.number(in: "Collection"))        // no number
        XCTAssertNil(ManualCollectionName.number(in: "Collection abc"))    // not a number
        XCTAssertNil(ManualCollectionName.number(in: "Collection 1 x"))    // trailing junk
        XCTAssertNil(ManualCollectionName.number(in: "My Collection 2"))   // wrong prefix
        XCTAssertNil(ManualCollectionName.number(in: "collection 2"))      // case-sensitive prefix
    }
}
