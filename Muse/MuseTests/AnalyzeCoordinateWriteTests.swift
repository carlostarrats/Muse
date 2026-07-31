//
//  AnalyzeCoordinateWriteTests.swift
//  MuseTests
//
//  The guarded coordinate write inside the analysis pass. Two rules matter:
//  the write is refused when the file's bytes moved mid-pass (same guard the
//  main analyze write uses), and coords_scanned_hash is stamped even when the
//  file carries NO GPS — the attempted-marker that stops a GPS-less file being
//  re-opened on every launch forever.
//

import XCTest
import GRDB
@testable import Muse

final class AnalyzeCoordinateWriteTests: XCTestCase {

    private func migrated() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func seed(_ q: DatabaseQueue, hash: String) throws {
        try q.write { db in
            try db.execute(sql:
                "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1',?,'image',0)",
                arguments: [hash])
        }
    }

    private func row(_ q: DatabaseQueue) throws -> FileRow? {
        try q.read { db in try FileRow.filter(FileRow.Columns.id == "f1").fetchOne(db) }
    }

    func testWritesCoordinatesUnderMatchingContentHash() async throws {
        let q = try migrated()
        try seed(q, hash: "h1")

        await AnalyzePipeline.writeCoordinates(
            fileID: "f1", hash: "h1",
            coord: Coordinate(lat: 38.7223, long: -9.1393), queue: q)

        let r = try row(q)
        XCTAssertEqual(r?.lat, 38.7223)
        XCTAssertEqual(r?.lon, -9.1393)
        XCTAssertEqual(r?.coords_scanned_hash, "h1")
    }

    func testStampsScannedHashEvenWithoutGPS() async throws {
        let q = try migrated()
        try seed(q, hash: "h1")

        await AnalyzePipeline.writeCoordinates(fileID: "f1", hash: "h1", coord: nil, queue: q)

        let r = try row(q)
        XCTAssertNil(r?.lat)
        XCTAssertNil(r?.lon)
        XCTAssertEqual(r?.coords_scanned_hash, "h1",
                       "a GPS-less file must be marked scanned, or it is re-read forever")
    }

    func testRefusesWriteWhenContentMovedMidPass() async throws {
        let q = try migrated()
        try seed(q, hash: "h2")
        // The header was read from h1; the row now holds h2 (re-indexed mid-pass).
        await AnalyzePipeline.writeCoordinates(
            fileID: "f1", hash: "h1",
            coord: Coordinate(lat: 1, long: 2), queue: q)

        let r = try row(q)
        XCTAssertNil(r?.lat)
        XCTAssertNil(r?.coords_scanned_hash,
                     "still pending, so the new bytes get their own GPS read")
    }

    func testRescanAfterEditOverwritesStaleCoordinates() async throws {
        let q = try migrated()
        try seed(q, hash: "h1")
        await AnalyzePipeline.writeCoordinates(
            fileID: "f1", hash: "h1", coord: Coordinate(lat: 1, long: 2), queue: q)

        try await q.write { db in
            try db.execute(sql: "UPDATE files SET content_hash = 'h2' WHERE id = 'f1'")
        }
        await AnalyzePipeline.writeCoordinates(
            fileID: "f1", hash: "h2", coord: Coordinate(lat: 10, long: 20), queue: q)

        let r = try row(q)
        XCTAssertEqual(r?.lat, 10)
        XCTAssertEqual(r?.coords_scanned_hash, "h2")
    }
}
