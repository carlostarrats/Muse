//
//  NoteStoreTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class NoteStoreTests: XCTestCase {
    /// A migrated queue with two files, each with an alive path in a distinct folder,
    /// plus a duplicate of file A living in a second folder (same file_id is NOT the
    /// case here — notes are keyed by (file_id, parent_dir), so we seed two folders
    /// under one file_id to prove scope isolation).
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f2','h2','image',0)")
        }
        return q
    }

    func testMigrationCreatesNotesTable() throws {
        let q = try makeQueue()
        let exists = try q.read { db in
            try Bool.fetchOne(db, sql:
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='notes'") ?? false
        }
        XCTAssertTrue(exists)
    }

    func testWriteThenReadRoundTrips() throws {
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("hello world", fileID: "f1", parentDir: "/A", updatedAt: 10, db: db)
        }
        let body = try q.read { db in try NoteStore.read(fileID: "f1", parentDir: "/A", db: db) }
        XCTAssertEqual(body, "hello world")
    }

    func testWriteReplacesExisting() throws {
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("first", fileID: "f1", parentDir: "/A", updatedAt: 10, db: db)
            try NoteStore.write("second", fileID: "f1", parentDir: "/A", updatedAt: 11, db: db)
        }
        let body = try q.read { db in try NoteStore.read(fileID: "f1", parentDir: "/A", db: db) }
        XCTAssertEqual(body, "second")
        let count = try q.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes")! }
        XCTAssertEqual(count, 1)
    }

    func testEmptyBodyDeletesRow() throws {
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("something", fileID: "f1", parentDir: "/A", updatedAt: 10, db: db)
            try NoteStore.write("   ", fileID: "f1", parentDir: "/A", updatedAt: 11, db: db)
        }
        let body = try q.read { db in try NoteStore.read(fileID: "f1", parentDir: "/A", db: db) }
        XCTAssertNil(body)
    }

    func testScopeIsolationSameFileTwoFolders() throws {
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("note in A", fileID: "f1", parentDir: "/A", updatedAt: 10, db: db)
            try NoteStore.write("note in B", fileID: "f1", parentDir: "/B", updatedAt: 10, db: db)
        }
        let a = try q.read { db in try NoteStore.read(fileID: "f1", parentDir: "/A", db: db) }
        let b = try q.read { db in try NoteStore.read(fileID: "f1", parentDir: "/B", db: db) }
        XCTAssertEqual(a, "note in A")
        XCTAssertEqual(b, "note in B")
    }

    func testSearchMatchesSubstringReturnsFileID() throws {
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("a memo about ducks", fileID: "f1", parentDir: "/A", updatedAt: 10, db: db)
            try NoteStore.write("unrelated", fileID: "f2", parentDir: "/B", updatedAt: 10, db: db)
        }
        let ids = try q.read { db in try NoteStore.searchIDs(term: "duck", db: db) }
        XCTAssertEqual(ids, ["f1"])
    }

    func testSearchEmptyTermReturnsNothing() throws {
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("anything", fileID: "f1", parentDir: "/A", updatedAt: 10, db: db)
        }
        let ids = try q.read { db in try NoteStore.searchIDs(term: "   ", db: db) }
        XCTAssertTrue(ids.isEmpty)
    }

    func testSearchWildcardIsLiteral() throws {
        // A note without a literal % must not match a "%" query (LIKE escaping).
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("plain text", fileID: "f1", parentDir: "/A", updatedAt: 10, db: db)
        }
        let ids = try q.read { db in try NoteStore.searchIDs(term: "%", db: db) }
        XCTAssertTrue(ids.isEmpty)
    }

    func testHydrateNewerLocalNoteSurvivesOlderEmptySidecar() throws {
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("my note", fileID: "f1", parentDir: "/A", updatedAt: 100, db: db)
            // Older sidecar with NO note must NOT delete the newer local note.
            try NoteStore.applyHydrated(nil, fileID: "f1", parentDir: "/A", incomingUpdatedAt: 50, db: db)
        }
        let body = try q.read { db in try NoteStore.read(fileID: "f1", parentDir: "/A", db: db) }
        XCTAssertEqual(body, "my note")
    }

    func testHydrateNewerSidecarDeletePropagates() throws {
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("old note", fileID: "f1", parentDir: "/A", updatedAt: 50, db: db)
            // Newer sidecar clearing the note DOES delete it.
            try NoteStore.applyHydrated(nil, fileID: "f1", parentDir: "/A", incomingUpdatedAt: 100, db: db)
        }
        let body = try q.read { db in try NoteStore.read(fileID: "f1", parentDir: "/A", db: db) }
        XCTAssertNil(body)
    }

    func testHydrateNewerSidecarNoteOverwritesOlderLocal() throws {
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("old", fileID: "f1", parentDir: "/A", updatedAt: 50, db: db)
            try NoteStore.applyHydrated("new", fileID: "f1", parentDir: "/A", incomingUpdatedAt: 100, db: db)
        }
        let body = try q.read { db in try NoteStore.read(fileID: "f1", parentDir: "/A", db: db) }
        XCTAssertEqual(body, "new")
    }

    func testHydrateIntoEmptyWritesNote() throws {
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.applyHydrated("fresh", fileID: "f1", parentDir: "/A", incomingUpdatedAt: 10, db: db)
        }
        let body = try q.read { db in try NoteStore.read(fileID: "f1", parentDir: "/A", db: db) }
        XCTAssertEqual(body, "fresh")
    }
}
