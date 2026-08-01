//
//  RediscoveryQueriesTests.swift
//  MuseTests
//
//  Rarely-seen order (never-viewed first, then oldest-viewed); on-this-day MD
//  match across years with a created_at fallback, newest first; shuffle
//  determinism under a fixed seed; kind restriction.
//

import XCTest
import GRDB
@testable import Muse

final class RediscoveryQueriesTests: XCTestCase {

    private func migrated() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        return queue
    }

    func testRarelySeenOrdersNeverViewedFirstThenOldest() throws {
        let queue = try migrated()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, created_at, last_viewed_at)
                VALUES ('f1','h1','image',0,100,500),
                       ('f2','h2','image',0,200,NULL),
                       ('f3','h3','image',0,300,200)
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1','f1','/r/f1.jpg',1), ('p2','f2','/r/f2.jpg',1), ('p3','f3','/r/f3.jpg',1)
                """)
        }
        try queue.read { db in
            XCTAssertEqual(try RediscoveryQueries.rarelySeen(db: db), ["f2", "f3", "f1"])
        }
    }

    func testKindRestrictionExcludesDocuments() throws {
        let queue = try migrated()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, created_at)
                VALUES ('f1','h1','image',0,0), ('f2','h2','text',0,0)
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1','f1','/r/f1.jpg',1), ('p2','f2','/r/f2.txt',1)
                """)
        }
        try queue.read { db in
            XCTAssertEqual(try RediscoveryQueries.rarelySeen(db: db), ["f1"])
        }
    }

    func testOnThisDayMatchesCaptureMDAcrossYearsNewestFirst() throws {
        let queue = try migrated()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, created_at)
                VALUES ('f1','h1','image',0,0), ('f2','h2','image',0,0)
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1','f1','/r/f1.jpg',1), ('p2','f2','/r/f2.jpg',1)
                """)
            // f1: 2020-06-21; f2: 2018-06-21.
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, capture_date, capture_md)
                VALUES ('f1', 1592742000, '06-21'), ('f2', 1529526000, '06-21')
                """)
        }
        try queue.read { db in
            XCTAssertEqual(try RediscoveryQueries.onThisDay(db: db, todayMD: "06-21",
                                                            currentYear: 2026),
                           ["f1", "f2"])
        }
    }

    func testOnThisDayExcludesCurrentYear() throws {
        let queue = try migrated()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, created_at)
                VALUES ('f1','h1','image',0,0)
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/r/f1.jpg',1)
                """)
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, capture_date, capture_md)
                VALUES ('f1', 1592742000, '06-21')
                """)
        }
        try queue.read { db in
            XCTAssertTrue(try RediscoveryQueries.onThisDay(db: db, todayMD: "06-21",
                                                           currentYear: 2020).isEmpty)
        }
    }

    func testOnThisDayFallsBackToCreatedAtWhenNoPhotoMetaRow() throws {
        let queue = try migrated()
        try queue.write { db in
            // 2020-06-21 15:00 UTC == 08:00 PDT — the same calendar day either way,
            // so this test is about the fallback JOIN, not about the zone.
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, created_at)
                VALUES ('f3','h3','image',0,1592742000)
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p3','f3','/r/f3.jpg',1)
                """)
        }
        try withTimeZone("America/Los_Angeles") {
            try queue.read { db in
                XCTAssertTrue(try RediscoveryQueries.onThisDay(db: db, todayMD: "06-21",
                                                               currentYear: 2026).contains("f3"))
            }
        }
    }

    /// The `created_at` fallback must test the month-day in LOCAL time, because
    /// `todayMD` is built from a local `Calendar` and `capture_md` is materialized
    /// in the local zone. Bare `'unixepoch'` is UTC, so an evening photo in the
    /// Americas landed on the next day's anniversary and was absent from its own.
    ///
    /// `1592802000` is 2020-06-21 **22:00 PDT** == 2020-06-22 **05:00 UTC**: the
    /// two readings disagree, which is the whole point of the fixture.
    func testOnThisDayFallbackUsesLocalNotUTCMonthDay() throws {
        let queue = try migrated()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, created_at)
                VALUES ('f4','h4','image',0,1592802000)
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p4','f4','/r/f4.jpg',1)
                """)
        }
        try withTimeZone("America/Los_Angeles") {
            try queue.read { db in
                // Surfaces on the day it was actually taken…
                XCTAssertTrue(try RediscoveryQueries.onThisDay(db: db, todayMD: "06-21",
                                                               currentYear: 2026).contains("f4"))
                // …and NOT on the following day, which is what the UTC reading gave.
                XCTAssertFalse(try RediscoveryQueries.onThisDay(db: db, todayMD: "06-22",
                                                                currentYear: 2026).contains("f4"))
            }
        }
    }

    /// The year exclusion is the same class: `currentYear` is a local
    /// `Calendar` year, so the column it is compared against must be read local
    /// too. 2019-12-31 20:00 PST is already 2020 in UTC.
    func testOnThisDayYearExclusionUsesLocalYear() throws {
        let queue = try migrated()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, created_at)
                VALUES ('f5','h5','image',0,0)
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p5','f5','/r/f5.jpg',1)
                """)
            // 2019-12-31 20:00 PST == 2020-01-01 04:00 UTC.
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, capture_date, capture_md)
                VALUES ('f5', 1577851200, '12-31')
                """)
        }
        try withTimeZone("America/Los_Angeles") {
            try queue.read { db in
                // Local year is 2019, so a 2020 "today" must still show it.
                XCTAssertTrue(try RediscoveryQueries.onThisDay(db: db, todayMD: "12-31",
                                                               currentYear: 2020).contains("f5"))
            }
        }
    }

    func testShuffleIsDeterministicUnderFixedSeed() throws {
        let queue = try migrated()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, created_at)
                VALUES ('f1','h1','image',0,0), ('f2','h2','image',0,0), ('f3','h3','image',0,0)
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1','f1','/r/f1.jpg',1), ('p2','f2','/r/f2.jpg',1), ('p3','f3','/r/f3.jpg',1)
                """)
        }
        try queue.read { db in
            XCTAssertEqual(try RediscoveryQueries.shuffle(db: db, seed: 42),
                           try RediscoveryQueries.shuffle(db: db, seed: 42))
            XCTAssertEqual(Set(try RediscoveryQueries.shuffle(db: db, seed: 42)),
                           ["f1", "f2", "f3"])
        }
    }

    /// The reservoir sample must still cover the whole library — a cursor that
    /// stops early, or a slot rule that only ever replaces the head, would
    /// silently sample from a prefix.
    func testShuffleSamplesFromTheWholeLibrary() throws {
        let queue = try migrated()
        try queue.write { db in
            var files = "INSERT INTO files (id, content_hash, kind, last_seen_at, created_at) VALUES "
            files += (0..<200).map { "('f\(String(format: "%03d", $0))','h\($0)','image',0,0)" }
                .joined(separator: ",")
            try db.execute(sql: files)
            var paths = "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES "
            paths += (0..<200).map {
                "('p\($0)','f\(String(format: "%03d", $0))','/r/f\($0).jpg',1)"
            }.joined(separator: ",")
            try db.execute(sql: paths)
        }
        try queue.read { db in
            var pooled = Set<String>()
            for seed in UInt64(1)...20 {
                pooled.formUnion(try RediscoveryQueries.shuffle(db: db, limit: 5, seed: seed))
            }
            // With a prefix-only sampler every seed returns from the same few
            // rows; a correct reservoir reaches deep into the id order.
            XCTAssertTrue(pooled.contains { $0 > "f150" },
                          "sampled ids never reached the tail of the library")
            XCTAssertGreaterThan(pooled.count, 20)
        }
    }

    func testSurfacesAreCapped() throws {
        let queue = try migrated()
        try queue.write { db in
            var files = "INSERT INTO files (id, content_hash, kind, last_seen_at, created_at) VALUES "
            files += (0..<10).map { "('f\($0)','h\($0)','image',0,0)" }.joined(separator: ",")
            try db.execute(sql: files)
            var paths = "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES "
            paths += (0..<10).map { "('p\($0)','f\($0)','/r/f\($0).jpg',1)" }.joined(separator: ",")
            try db.execute(sql: paths)
        }
        try queue.read { db in
            XCTAssertEqual(try RediscoveryQueries.rarelySeen(db: db, limit: 3).count, 3)
            XCTAssertEqual(try RediscoveryQueries.shuffle(db: db, limit: 3, seed: 1).count, 3)
        }
    }
}
