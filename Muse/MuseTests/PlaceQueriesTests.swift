//
//  PlaceQueriesTests.swift
//  MuseTests
//
//  Grouping, cover = most recent member, latestAt falls back to modified_at,
//  NULL place_key excluded (no "Unknown" group).
//

import XCTest
import GRDB
@testable import Muse

final class PlaceQueriesTests: XCTestCase {

    private func seeded() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, modified_at)
                VALUES ('f1','h1','image',0,100), ('f2','h2','image',0,200),
                       ('f3','h3','image',0,300), ('f4','h4','image',0,400)
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1','f1','/root/a/f1.jpg',1), ('p2','f2','/root/a/f2.jpg',1),
                       ('p3','f3','/root/a/f3.jpg',1), ('p4','f4','/root/a/f4.jpg',1)
                """)
            try db.execute(sql: """
                INSERT INTO places (file_id, geocoded_hash, dataset_version, city, admin, country, place_key)
                VALUES ('f1','h1',1,'Lisboa','Lisbon','PT','lisboa|lisbon|pt'),
                       ('f2','h2',1,'Lisboa','Lisbon','PT','lisboa|lisbon|pt'),
                       ('f3','h3',1,'Porto','Porto','PT','porto|porto|pt'),
                       ('f4','h4',1,NULL,NULL,NULL,NULL)
                """)
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, capture_date) VALUES ('f1', 500), ('f2', 1500)
                """)
        }
        return queue
    }

    func testGroupsByPlaceKeyWithCounts() throws {
        try seeded().read { db in
            let groups = try PlaceQueries.groups(db: db)
            XCTAssertEqual(groups.first { $0.key == "lisboa|lisbon|pt" }?.count, 2)
        }
    }

    func testNullPlaceKeyExcluded() throws {
        try seeded().read { db in
            let groups = try PlaceQueries.groups(db: db)
            XCTAssertEqual(groups.count, 2)
            XCTAssertEqual(groups.reduce(0) { $0 + $1.count }, 3)   // f4 excluded
        }
    }

    func testCoverPathIsMostRecentMember() throws {
        try seeded().read { db in
            let lisboa = try PlaceQueries.groups(db: db).first { $0.key == "lisboa|lisbon|pt" }
            // f2's capture_date (1500) beats f1's (500).
            XCTAssertEqual(lisboa?.coverPath, "/root/a/f2.jpg")
            XCTAssertEqual(lisboa?.latestAt, 1500)
        }
    }

    func testLatestAtFallsBackToModifiedAt() throws {
        try seeded().read { db in
            let porto = try PlaceQueries.groups(db: db).first { $0.key == "porto|porto|pt" }
            XCTAssertEqual(porto?.latestAt, 300)   // f3 has no photo_meta row
        }
    }

    func testDisplayNameResolvesCountryCode() {
        let group = PlaceGroup(key: "k", city: "Lisboa", admin: "Lisbon", countryCode: "PT",
                               count: 1, latestAt: 0, coverPath: nil)
        XCTAssertTrue(group.displayName.hasPrefix("Lisboa, "))
        XCTAssertFalse(group.displayName.hasSuffix("PT"))
    }
}
