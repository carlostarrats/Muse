//
//  PhotoSearchTests.swift
//  MuseTests
//
//  Token → SQL over an in-memory DB: AND intersection across tokens; rating
//  tokens carry per-(file_id, parent_dir) dir restrictions while every other
//  token is content-derived and unrestricted; capture-DESC ordering; the `in:`
//  created_at fallback for files with no photo_meta row.
//

import XCTest
import GRDB
@testable import Muse

final class PhotoSearchTests: XCTestCase {

    private func seeded() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, created_at, modified_at)
                VALUES ('f1','h1','image',0,1000,1000),
                       ('f2','h2','image',0,2000,2000),
                       ('f3','h3','raw',  0,15000000,3000)
                """)
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, camera_make, camera_model, lens, iso, f_number, capture_date)
                VALUES ('f1','FUJIFILM','X100V','23mm', 400, 2.0, 1500),
                       ('f2','FUJIFILM','X100V','50mm',3200, 2.8, 2500)
                """)
            try db.execute(sql: """
                INSERT INTO places (file_id, geocoded_hash, dataset_version, city, admin, country, place_key)
                VALUES ('f1','h1',1,'Lisboa','Lisbon','PT','lisboa|lisbon|pt')
                """)
        }
        return queue
    }

    func testCameraTokenMatchesModel() throws {
        try seeded().read { db in
            XCTAssertEqual(try PhotoSearch.filter(tokens: [.camera("x100v")], db: db)?.idSet,
                           ["f1", "f2"])
        }
    }

    func testLensToken() throws {
        try seeded().read { db in
            XCTAssertEqual(try PhotoSearch.filter(tokens: [.lens("50mm")], db: db)?.idSet, ["f2"])
        }
    }

    func testIsoRangeIntersection() throws {
        try seeded().read { db in
            let result = try PhotoSearch.filter(
                tokens: [.camera("x100v"), .iso(.init(op: .gt, value: 1000))], db: db)
            XCTAssertEqual(result?.idSet, ["f2"])
        }
    }

    func testApertureToken() throws {
        try seeded().read { db in
            XCTAssertEqual(try PhotoSearch.filter(
                tokens: [.aperture(.init(op: .lte, value: 2.0))], db: db)?.idSet, ["f1"])
        }
    }

    func testNearTokenMatchesPlace() throws {
        try seeded().read { db in
            XCTAssertEqual(try PhotoSearch.filter(tokens: [.near("Lisboa")], db: db)?.idSet, ["f1"])
        }
    }

    func testNearTokenMatchesLocalizedCountryName() throws {
        try seeded().read { db in
            // The DB stores "PT"; the user types the display name.
            XCTAssertEqual(try PhotoSearch.filter(tokens: [.near("Portugal")], db: db)?.idSet,
                           ["f1"])
        }
    }

    func testKindTokenMatchesRawGroup() throws {
        try seeded().read { db in
            XCTAssertEqual(try PhotoSearch.filter(tokens: [.kind(.raw)], db: db)?.idSet, ["f3"])
        }
    }

    func testCaptureDateFallbackToCreatedAt() throws {
        try seeded().read { db in
            // f3 has no photo_meta row, so `in:` falls back to created_at
            // (mid-1970, comfortably inside the local-time year window).
            let result = try PhotoSearch.filter(
                tokens: [.inDate(.init(year: 1970, month: nil, day: nil))], db: db)
            XCTAssertTrue(result?.idSet.contains("f3") ?? false)
            XCTAssertFalse(try PhotoSearch.filter(
                tokens: [.inDate(.init(year: 2019, month: nil, day: nil))], db: db)?
                .idSet.contains("f3") ?? true)
        }
    }

    func testResultOrderedByCaptureDateDescending() throws {
        try seeded().read { db in
            XCTAssertEqual(try PhotoSearch.filter(tokens: [.camera("x100v")], db: db)?.ids,
                           ["f2", "f1"])
        }
    }

    func testEmptyTokensReturnsNil() throws {
        try seeded().read { db in
            XCTAssertNil(try PhotoSearch.filter(tokens: [], db: db))
        }
    }

    func testTextAndColorTokensAreNotIntersectedHere() throws {
        // Both are handled by SearchService's existing legs — a query of only
        // those has nothing for PhotoSearch to intersect.
        try seeded().read { db in
            XCTAssertNil(try PhotoSearch.filter(tokens: [.text("receipt"), .color("red")], db: db))
        }
    }

    func testRatingTokenCarriesDirRestrictions() throws {
        let queue = try seeded()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source)
                VALUES ('t1','f1','/A','\u{2605}\u{2605}\u{2605}\u{2605}','manual')
                """)
        }
        try queue.read { db in
            let result = try PhotoSearch.filter(tokens: [.rating(atLeast: 4)], db: db)
            XCTAssertEqual(result?.idSet, ["f1"])
            XCTAssertEqual(result?.dirRestrictions["f1"], ["/A"])
        }
    }

    func testRatingTokenIsAtLeast() throws {
        let queue = try seeded()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source)
                VALUES ('t1','f1','/A','\u{2605}\u{2605}','manual')
                """)
        }
        try queue.read { db in
            XCTAssertNil(try PhotoSearch.filter(tokens: [.rating(atLeast: 4)], db: db)?
                .idSet.first)
            XCTAssertEqual(try PhotoSearch.filter(tokens: [.rating(atLeast: 2)], db: db)?.idSet,
                           ["f1"])
        }
    }

    func testEmptyIntersectionShortCircuits() throws {
        try seeded().read { db in
            let result = try PhotoSearch.filter(
                tokens: [.camera("nikon"), .iso(.init(op: .eq, value: 400))], db: db)
            XCTAssertEqual(result?.idSet, [])
            XCTAssertEqual(result?.ids, [])
        }
    }
}
