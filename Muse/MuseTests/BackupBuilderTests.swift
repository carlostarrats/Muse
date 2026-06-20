//
//  BackupBuilderTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class BackupBuilderTests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at, caption, analyzed_hash) VALUES ('f1', 'h1', 'image', 0, 'a cat', 'h1')")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1', 'f1', '/old/Pics/cat.jpg', 1)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('t1', 'f1', '/old/Pics', 'cat', 'manual')")
            try db.execute(sql: "INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, cover_file_id, sort_order) VALUES ('c1', 'Cats', 0, 'manual', 1, 1, 'f1', 0)")
            try db.execute(sql: "INSERT INTO collection_members (collection_id, file_id, added_by) VALUES ('c1', 'f1', 'manual')")
            try db.execute(sql: "INSERT INTO starred_folders (id, absolute_path, display_name, added_at) VALUES ('s1', '/old/Pics/Fav', 'Fav', 0)")
        }
        return q
    }

    func testBuildReKeysMembershipToContentHash() async throws {
        let q = try makeQueue()
        let archive = try await BackupBuilder.build(
            queue: q, roots: [BackupRoot(path: "/old/Pics", display_name: "Pics")],
            createdAt: 123, appVersion: "1.0")

        XCTAssertEqual(archive.files.count, 1)
        let file = archive.files[0]
        XCTAssertEqual(file.content_hash, "h1")
        XCTAssertEqual(file.meta.caption, "a cat")
        XCTAssertTrue(file.meta.tags.isEmpty)
        XCTAssertEqual(file.occurrences.count, 1)
        XCTAssertEqual(file.occurrences[0].original_path, "/old/Pics/cat.jpg")
        XCTAssertEqual(file.occurrences[0].parent_dir, "/old/Pics")
        XCTAssertEqual(file.occurrences[0].tags.map(\.label), ["cat"])

        XCTAssertEqual(archive.collections.count, 1)
        let c = archive.collections[0]
        XCTAssertEqual(c.cover_hash, "h1")
        XCTAssertEqual(c.members.map(\.content_hash), ["h1"])
        XCTAssertEqual(archive.stars.map(\.path), ["/old/Pics/Fav"])
    }

    func testFileWithNoAlivePathIsSkipped() async throws {
        let q = try makeQueue()
        try await q.write { db in
            try db.execute(sql: "UPDATE paths SET is_alive = 0 WHERE id = 'p1'")
        }
        let archive = try await BackupBuilder.build(
            queue: q, roots: [], createdAt: 0, appVersion: nil)
        XCTAssertTrue(archive.files.isEmpty)
        XCTAssertEqual(archive.collections.first?.members.count, 0)
    }
}
