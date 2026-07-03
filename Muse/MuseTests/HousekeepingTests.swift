//
//  HousekeepingTests.swift
//  MuseTests
//
//  The 180-day retention prune is a PERMANENT DELETE, so its reachability
//  rules are load-bearing: a root it can't see reads as "unreachable" and the
//  whole subtree is purged. The shipped-class bug guarded here: the iCloud
//  "Muse" root is never a bookmark root, so it must be passed via
//  `icloudRoot` — and when that can't resolve (signed out, Debug build),
//  ubiquity-container paths are protected wholesale (fail safe).
//

import XCTest
import GRDB
@testable import Muse

final class HousekeepingTests: XCTestCase {

    private func freshQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    /// Insert one file with a single alive path and an ancient last_seen_at.
    private func insertOldFile(_ q: DatabaseQueue, id: String, path: String) throws {
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES (?,?, 'image', 0)",
                           arguments: [id, "h-\(id)"])
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES (?,?,?,1)",
                           arguments: ["p-\(id)", id, path])
        }
    }

    private func fileCount(_ q: DatabaseQueue) throws -> Int {
        try q.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files")! }
    }

    func testKeepsFilesUnderAPassedRoot() async throws {
        let q = try freshQueue()
        try insertOldFile(q, id: "f1", path: "/roots/a/x.png")
        await Housekeeping.pruneUnreachable(queue: q, rootPaths: ["/roots/a"], icloudRoot: nil)
        XCTAssertEqual(try fileCount(q), 1)
    }

    func testPrunesOldUnreachableFiles() async throws {
        let q = try freshQueue()
        try insertOldFile(q, id: "f1", path: "/gone/x.png")
        try await q.write { db in
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('t1','f1','blue','manual',NULL,'/gone')")
            try db.execute(sql: "INSERT INTO files_fts (file_id, basename, ocr_text, caption) VALUES ('f1','x.png','','')")
        }
        await Housekeeping.pruneUnreachable(queue: q, rootPaths: ["/roots/a"], icloudRoot: nil)
        XCTAssertEqual(try fileCount(q), 0)
        try await q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM paths"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files_fts WHERE file_id='f1'"), 0)
        }
    }

    func testKeepsRecentlySeenFilesEvenIfUnreachable() async throws {
        let q = try freshQueue()
        try await q.write { db in
            let now = Int64(Date().timeIntervalSince1970)
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',?)",
                           arguments: [now])
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/gone/x.png',1)")
        }
        await Housekeeping.pruneUnreachable(queue: q, rootPaths: [], icloudRoot: nil)
        XCTAssertEqual(try fileCount(q), 1)
    }

    func testICloudRootProtectsItsFiles() async throws {
        // The iCloud "Muse" root is NOT a bookmark root — losing it from the
        // reachable set hard-deleted its stale-but-alive files (shipped-class
        // data-loss bug this parameter exists to prevent).
        let q = try freshQueue()
        let icloud = "/Users/u/Library/Mobile Documents/iCloud~com~tarrats~Muse/Documents"
        try insertOldFile(q, id: "f1", path: icloud + "/pic.png")
        await Housekeeping.pruneUnreachable(queue: q, rootPaths: ["/roots/a"], icloudRoot: icloud)
        XCTAssertEqual(try fileCount(q), 1)
    }

    func testUnresolvedICloudProtectsUbiquityPathsWholesale() async throws {
        // Container unresolvable right now (signed out / Debug build without
        // the entitlement): fail SAFE — never hard-delete rows we can't
        // attribute to a live root.
        let q = try freshQueue()
        let icloud = "/Users/u/Library/Mobile Documents/iCloud~com~tarrats~Muse/Documents"
        try insertOldFile(q, id: "f1", path: icloud + "/pic.png")
        try insertOldFile(q, id: "f2", path: "/gone/x.png")
        await Housekeeping.pruneUnreachable(queue: q, rootPaths: ["/roots/a"], icloudRoot: nil)
        try await q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files WHERE id='f1'"), 1,
                           "ubiquity path survives when the container can't resolve")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files WHERE id='f2'"), 0,
                           "a genuinely removed local folder still prunes")
        }
    }

    func testSiblingPrefixDoesNotProtect() async throws {
        // "/roots/a" must not protect "/roots/a Extra" (trailing-slash rule).
        let q = try freshQueue()
        try insertOldFile(q, id: "f1", path: "/roots/a Extra/x.png")
        await Housekeeping.pruneUnreachable(queue: q, rootPaths: ["/roots/a"], icloudRoot: nil)
        XCTAssertEqual(try fileCount(q), 0)
    }
}
