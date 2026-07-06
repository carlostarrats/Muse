//
//  IndexerFastPathTests.swift
//  MuseTests
//
//  DB-backed coverage that the retained single-file `isUnchanged` wrapper wires
//  stored rows into decideIndexAction correctly and applies the last_seen touch,
//  plus the batched folder-open discovery read (P4).
//

import XCTest
import GRDB
@testable import Muse

final class IndexerFastPathTests: XCTestCase {

    private func freshQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func seed(_ q: DatabaseQueue, hash: String?, size: Int64?, mtime: Int64?,
                      lastSeen: Int64) throws {
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, size_bytes, modified_at, last_seen_at) VALUES ('f1',?, 'image', ?, ?, ?)",
                           arguments: [hash, size, mtime, lastSeen])
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/x.png',1)")
        }
    }

    func testICloudTrustsHashIgnoresMetadata() throws {
        let q = try freshQueue()
        try seed(q, hash: "h1", size: 100, mtime: 50, lastSeen: 0)
        // iCloud + wrong size/mtime → still unchanged.
        XCTAssertTrue(Indexer.isUnchanged(absPath: "/a/x.png", sizeBytes: 999, modifiedAt: 999,
                                          isUbiquitous: true, now: 10, queue: q))
    }

    func testLocalMatchUnchangedMismatchChanged() throws {
        let q = try freshQueue()
        try seed(q, hash: "h1", size: 100, mtime: 50, lastSeen: 0)
        XCTAssertTrue(Indexer.isUnchanged(absPath: "/a/x.png", sizeBytes: 100, modifiedAt: 50,
                                          isUbiquitous: false, now: 10, queue: q))
        XCTAssertFalse(Indexer.isUnchanged(absPath: "/a/x.png", sizeBytes: 101, modifiedAt: 50,
                                           isUbiquitous: false, now: 10, queue: q))
    }

    func testNullHashAlwaysChanged() throws {
        let q = try freshQueue()
        try seed(q, hash: nil, size: 100, mtime: 50, lastSeen: 0)
        XCTAssertFalse(Indexer.isUnchanged(absPath: "/a/x.png", sizeBytes: 100, modifiedAt: 50,
                                           isUbiquitous: false, now: 10, queue: q))
        XCTAssertFalse(Indexer.isUnchanged(absPath: "/a/x.png", sizeBytes: 100, modifiedAt: 50,
                                           isUbiquitous: true, now: 10, queue: q))
    }

    func testNoAlivePathChanged() throws {
        let q = try freshQueue()
        XCTAssertFalse(Indexer.isUnchanged(absPath: "/a/missing.png", sizeBytes: 1, modifiedAt: 1,
                                           isUbiquitous: false, now: 10, queue: q))
    }

    func testStaleLastSeenIsTouched() throws {
        let q = try freshQueue()
        try seed(q, hash: "h1", size: 100, mtime: 50, lastSeen: 0)   // stale: now - 0 > 86400
        _ = Indexer.isUnchanged(absPath: "/a/x.png", sizeBytes: 100, modifiedAt: 50,
                                isUbiquitous: false, now: 200_000, queue: q)
        let ls = try q.read { try Int64.fetchOne($0, sql: "SELECT last_seen_at FROM files WHERE id='f1'") }
        XCTAssertEqual(ls, 200_000)
    }

    func testFreshLastSeenNotTouched() throws {
        let q = try freshQueue()
        try seed(q, hash: "h1", size: 100, mtime: 50, lastSeen: 190_000)   // fresh: 200000 - 190000 < 86400
        _ = Indexer.isUnchanged(absPath: "/a/x.png", sizeBytes: 100, modifiedAt: 50,
                                isUbiquitous: false, now: 200_000, queue: q)
        let ls = try q.read { try Int64.fetchOne($0, sql: "SELECT last_seen_at FROM files WHERE id='f1'") }
        XCTAssertEqual(ls, 190_000, "a fresh last_seen must not be rewritten")
    }

    // MARK: batched discovery (P4)

    func testLoadStoredIdentitiesReturnsJoinedRows() throws {
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, size_bytes, modified_at, last_seen_at) VALUES ('f1','h1','image',100,50,7)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/x.png',1)")
            // A dead path and a null-file_id path must NOT appear in the map.
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p2','f1','/a/dead.png',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p3',NULL,'/a/orphan.png',1)")
        }
        let map = Indexer.loadStoredIdentities(
            absPaths: ["/a/x.png", "/a/dead.png", "/a/orphan.png", "/a/unknown.png"], queue: q)
        XCTAssertEqual(map.count, 1)
        let s = try XCTUnwrap(map["/a/x.png"])
        XCTAssertEqual(s.fileID, "f1")
        XCTAssertEqual(s.contentHash, "h1")
        XCTAssertEqual(s.size, 100)
        XCTAssertEqual(s.mtime, 50)
        XCTAssertEqual(s.lastSeen, 7)
    }

    // The core "old and new paths agree" guarantee: over the same fixture, the
    // set of paths the batched read+decision flags for hashing equals the set
    // the per-file isUnchanged wrapper flags.
    func testBatchedDiscoveryAgreesWithPerFileWrapper() throws {
        let q = try freshQueue()
        try q.write { db in
            // unchanged-local
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, size_bytes, modified_at, last_seen_at) VALUES ('f1','h1','image',100,50,0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/keep.png',1)")
            // changed-local (size differs on disk)
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, size_bytes, modified_at, last_seen_at) VALUES ('f2','h2','image',200,60,0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p2','f2','/a/edit.png',1)")
            // null-hash
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, size_bytes, modified_at, last_seen_at) VALUES ('f3',NULL,'image',300,70,0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p3','f3','/a/nohash.png',1)")
        }
        // On-disk metadata per path (as the loop would read via resourceValues).
        let onDisk: [String: (Int64?, Int64?, Bool)] = [   // (size, mtime, isUbiquitous)
            "/a/keep.png":   (100, 50, false),   // matches → unchanged
            "/a/edit.png":   (201, 60, false),   // size differs → needs hashing
            "/a/nohash.png": (300, 70, false),   // null hash → needs hashing
            "/a/new.png":    (1,   1,  false),   // unknown path → needs hashing
        ]
        let paths = Array(onDisk.keys)
        let map = Indexer.loadStoredIdentities(absPaths: paths, queue: q)

        var batched = Set<String>()
        for p in paths {
            let (sz, mt, ub) = onDisk[p]!
            if Indexer.decideIndexAction(isDataless: false, force: false, isUbiquitous: ub,
                                         stored: map[p], onDiskSize: sz, onDiskMtime: mt) == .needsHashing {
                batched.insert(p)
            }
        }
        var perFile = Set<String>()
        for p in paths {
            let (sz, mt, ub) = onDisk[p]!
            if !Indexer.isUnchanged(absPath: p, sizeBytes: sz, modifiedAt: mt,
                                    isUbiquitous: ub, now: 10, queue: q) {
                perFile.insert(p)
            }
        }
        XCTAssertEqual(batched, perFile)
        XCTAssertEqual(batched, ["/a/edit.png", "/a/nohash.png", "/a/new.png"])
    }

    func testBatchedLastSeenTouchUpdatesAllIDs() throws {
        let q = try freshQueue()
        try q.write { db in
            for i in 1...3 {
                try db.execute(sql: "INSERT INTO files (id, content_hash, kind, size_bytes, modified_at, last_seen_at) VALUES (?, ?, 'image', 10, 20, 0)",
                               arguments: ["f\(i)", "h\(i)"])
            }
        }
        let ids = ["f1", "f2", "f3"]
        try q.write { db in
            let marks = databaseQuestionMarks(count: ids.count)
            try db.execute(sql: "UPDATE files SET last_seen_at = ? WHERE id IN (\(marks))",
                           arguments: StatementArguments([Int64(200_000)] + ids))
        }
        let seen = try q.read { try Int64.fetchAll($0, sql: "SELECT last_seen_at FROM files ORDER BY id") }
        XCTAssertEqual(seen, [200_000, 200_000, 200_000])
    }
}
