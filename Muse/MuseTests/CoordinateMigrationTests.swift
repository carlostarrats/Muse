//
//  CoordinateMigrationTests.swift
//  MuseTests
//
//  v13_coordinates: files.lat/lon/coords_scanned_hash + a partial index.
//

import XCTest
import GRDB
@testable import Muse

final class CoordinateMigrationTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    func testV13AddsCoordinateColumnsAndIndex() throws {
        let queue = try makeQueue()
        try queue.read { db in
            let columns = try db.columns(in: "files").map(\.name)
            XCTAssertTrue(columns.contains("lat"))
            XCTAssertTrue(columns.contains("lon"))
            XCTAssertTrue(columns.contains("coords_scanned_hash"))
            let indexes = try db.indexes(on: "files")
            XCTAssertTrue(indexes.contains { $0.name == "files_coords_idx" })
        }
    }

    func testV13IsIdempotentAndPreservesExistingRows() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at)
                VALUES ('f1', 'hash1', 'image', 0)
                """)
        }
        // Re-running migrate on an already-migrated queue is a no-op (GRDB's
        // registered-migration tracking), and existing rows must survive with
        // NULL coordinate columns.
        try Database.makeMigrator().migrate(queue)

        try queue.read { db in
            let row = try FileRow.filter(FileRow.Columns.id == "f1").fetchOne(db)
            XCTAssertNotNil(row)
            XCTAssertNil(row?.lat)
            XCTAssertNil(row?.lon)
            XCTAssertNil(row?.coords_scanned_hash)
        }
    }

    func testCoordinatesRoundTrip() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, lat, lon, coords_scanned_hash)
                VALUES ('f2', 'hash2', 'image', 0, 38.7223, -9.1393, 'hash2')
                """)
        }
        try queue.read { db in
            let row = try FileRow.filter(FileRow.Columns.id == "f2").fetchOne(db)
            XCTAssertEqual(row?.lat, 38.7223)
            XCTAssertEqual(row?.lon, -9.1393)
            XCTAssertEqual(row?.coords_scanned_hash, "hash2")
        }
    }
}
