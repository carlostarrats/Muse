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
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, created_at)
                VALUES ('f3','h3','image',0,1592742000)
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p3','f3','/r/f3.jpg',1)
                """)
        }
        try queue.read { db in
            XCTAssertTrue(try RediscoveryQueries.onThisDay(db: db, todayMD: "06-21",
                                                           currentYear: 2026).contains("f3"))
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
