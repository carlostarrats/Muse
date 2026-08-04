//
//  TagFolderScopeTests.swift
//  MuseTests
//
//  Rating exclusivity when tag rows from two scopes land on one — the case
//  `FileMoveMigration` creates when a file moves into a folder it is already
//  rated in.
//
//  This file used to also cover `Indexer.inheritVisionTags` (fan a shared
//  row's vision tags into a new folder's scope) and `Indexer.unionTags` (merge
//  two identities' tags on a hash collision). Both functions were deleted with
//  per-file identity on 2026-08-03: a copy now gets its own row and inherits
//  everything outright, and two rows may legally share a content_hash, so
//  there is no collision to merge.
//

import XCTest
import GRDB
@testable import Muse

final class TagFolderScopeTests: XCTestCase {

    private func migrated() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }



    func testCollapseRatingsIsPerFolderAndLeavesNonRatings() throws {
        let q = try migrated()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('f','image',0)")
            // /A has two ratings + a real tag; /B has a single rating.
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('a1','f','/A','\u{2605}','manual')")
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('a2','f','/A','\u{2605}\u{2605}\u{2605}','manual')")
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('a3','f','/A','dog','manual')")
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('b1','f','/B','\u{2605}\u{2605}','manual')")

            try Indexer.collapseRatings(db: db, fileID: "f", parentDir: nil)
        }
        try q.read { db in
            // /A collapses to the highest rating, non-rating tag untouched.
            XCTAssertEqual(try String.fetchAll(db, sql:
                "SELECT label FROM tags WHERE file_id='f' AND parent_dir='/A' ORDER BY label"),
                ["dog", "\u{2605}\u{2605}\u{2605}"])
            // /B's lone rating is left alone.
            XCTAssertEqual(try String.fetchAll(db, sql:
                "SELECT label FROM tags WHERE file_id='f' AND parent_dir='/B'"),
                ["\u{2605}\u{2605}"])
        }
    }
}
