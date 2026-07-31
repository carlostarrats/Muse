//
//  PhotoTraitsMigrationTests.swift
//  MuseTests
//
//  v19_photo_traits: one shared table for faces + pets + sharpness, all
//  raster-derived scalars from a single decode. traits_version covers
//  future trait additions without a new marker/table.
//

import XCTest
import GRDB
@testable import Muse

final class PhotoTraitsMigrationTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func insertFile(_ db: GRDB.Database, id: String) throws {
        try db.execute(sql: """
            INSERT INTO files (id, content_hash, kind, last_seen_at)
            VALUES (?, ?, 'image', 0)
            """, arguments: [id, id + "-hash"])
    }

    func testTableExistsWithExpectedColumns() throws {
        let q = try makeQueue()
        try q.read { db in
            XCTAssertTrue(try db.tableExists("photo_traits"))
            let columns = try db.columns(in: "photo_traits").map(\.name)
            for expected in ["file_id", "traits_scanned_hash", "traits_version",
                              "face_count", "largest_face_frac", "face_quality",
                              "pet_count", "sharpness"] {
                XCTAssertTrue(columns.contains(expected), "missing column \(expected)")
            }
        }
    }

    func testRowCascadesOnFileDelete() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f1")
            var row = PhotoTraitsRow(file_id: "f1", traits_scanned_hash: "f1-hash",
                                      traits_version: 1, face_count: 1,
                                      largest_face_frac: 0.2, face_quality: 0.7,
                                      pet_count: 0, sharpness: 3.2)
            try row.insert(db)
            try db.execute(sql: "DELETE FROM files WHERE id = 'f1'")
        }
        let remaining = try q.read { db in try PhotoTraitsRow.fetchAll(db) }
        XCTAssertTrue(remaining.isEmpty, "photo_traits row must cascade-delete with its file")
    }

    func testNullTraitFieldsRoundTripAsAttemptedMarker() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f2")
            var row = PhotoTraitsRow(file_id: "f2", traits_scanned_hash: "f2-hash",
                                      traits_version: 1, face_count: nil,
                                      largest_face_frac: nil, face_quality: nil,
                                      pet_count: nil, sharpness: nil)
            try row.insert(db)
        }
        let row = try q.read { db in try PhotoTraitsRow.fetchOne(db, key: "f2") }
        XCTAssertNotNil(row, "a NULL-field row is a legitimate attempted-marker, not absence")
        XCTAssertNil(row?.face_count)
    }

    func testMigrationIsIdempotentAfterV17() throws {
        // Registering the migrator twice against the same queue must not throw.
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try Database.makeMigrator().migrate(q)
        try q.read { db in XCTAssertTrue(try db.tableExists("photo_traits")) }
    }
}
