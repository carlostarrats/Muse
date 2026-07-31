//
//  AnalyzeCoordinateWriteTests.swift
//  MuseTests
//
//  The guarded header write inside the analysis pass. Three rules matter:
//  the write is refused when the file's bytes moved mid-pass (same guard the
//  main analyze write uses); coords_scanned_hash / exif_scanned_hash are
//  stamped even when the file carries NO GPS or EXIF — the attempted-markers
//  that stop such a file being re-opened on every launch forever; and a write
//  whose markers are both already current is skipped entirely, so externally
//  supplied metadata can't be clobbered by a header re-read.
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

        await AnalyzePipeline.writePhotoHeader(
            fileID: "f1", hash: "h1",
            header: PhotoHeader(coordinate: Coordinate(lat: 38.7223, long: -9.1393)),
            queue: q)

        let r = try row(q)
        XCTAssertEqual(r?.lat, 38.7223)
        XCTAssertEqual(r?.lon, -9.1393)
        XCTAssertEqual(r?.coords_scanned_hash, "h1")
    }

    func testStampsScannedHashEvenWithoutGPS() async throws {
        let q = try migrated()
        try seed(q, hash: "h1")

        await AnalyzePipeline.writePhotoHeader(fileID: "f1", hash: "h1",
                                               header: PhotoHeader(), queue: q)

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
        await AnalyzePipeline.writePhotoHeader(
            fileID: "f1", hash: "h1",
            header: PhotoHeader(coordinate: Coordinate(lat: 1, long: 2)), queue: q)

        let r = try row(q)
        XCTAssertNil(r?.lat)
        XCTAssertNil(r?.coords_scanned_hash,
                     "still pending, so the new bytes get their own GPS read")
    }

    func testRescanAfterEditOverwritesStaleCoordinates() async throws {
        let q = try migrated()
        try seed(q, hash: "h1")
        await AnalyzePipeline.writePhotoHeader(
            fileID: "f1", hash: "h1",
            header: PhotoHeader(coordinate: Coordinate(lat: 1, long: 2)), queue: q)

        try await q.write { db in
            try db.execute(sql: "UPDATE files SET content_hash = 'h2' WHERE id = 'f1'")
        }
        await AnalyzePipeline.writePhotoHeader(
            fileID: "f1", hash: "h2",
            header: PhotoHeader(coordinate: Coordinate(lat: 10, long: 20)), queue: q)

        let r = try row(q)
        XCTAssertEqual(r?.lat, 10)
        XCTAssertEqual(r?.coords_scanned_hash, "h2")
    }

    func testStampsExifMarkerAndWritesPhotoMeta() async throws {
        let q = try migrated()
        try seed(q, hash: "h1")
        var exif = ExifFields()
        exif.cameraMake = "FUJIFILM"
        exif.cameraModel = "X100V"
        exif.iso = 400
        exif.captureDate = 1_561_120_200
        exif.captureMD = "06-21"

        await AnalyzePipeline.writePhotoHeader(
            fileID: "f1", hash: "h1", header: PhotoHeader(exif: exif), queue: q)

        let meta = try await q.read { db in
            try PhotoMetaRow.filter(Column("file_id") == "f1").fetchOne(db)
        }
        XCTAssertEqual(meta?.camera_model, "X100V")
        XCTAssertEqual(meta?.capture_md, "06-21")
        XCTAssertEqual(meta?.exif_scanned_hash, "h1")
    }

    func testStampsExifMarkerWithNoExifPresent() async throws {
        let q = try migrated()
        try seed(q, hash: "h1")
        await AnalyzePipeline.writePhotoHeader(fileID: "f1", hash: "h1",
                                               header: PhotoHeader(), queue: q)
        let meta = try await q.read { db in
            try PhotoMetaRow.filter(Column("file_id") == "f1").fetchOne(db)
        }
        XCTAssertEqual(meta?.exif_scanned_hash, "h1",
                       "an EXIF-less file must be marked scanned, or it is re-read forever")
        XCTAssertNil(meta?.camera_make)
    }

    func testSkipsWriteWhenBothMarkersAlreadyCurrent() async throws {
        let q = try migrated()
        try seed(q, hash: "h1")
        var exif = ExifFields()
        exif.captureDate = 111
        await AnalyzePipeline.writePhotoHeader(
            fileID: "f1", hash: "h1",
            header: PhotoHeader(coordinate: Coordinate(lat: 1, long: 2), exif: exif),
            queue: q)

        // A later header re-read that finds nothing must not erase what's
        // there — both markers already equal this content hash.
        await AnalyzePipeline.writePhotoHeader(fileID: "f1", hash: "h1",
                                               header: PhotoHeader(), queue: q)

        let r = try row(q)
        XCTAssertEqual(r?.lat, 1)
        let meta = try await q.read { db in
            try PhotoMetaRow.filter(Column("file_id") == "f1").fetchOne(db)
        }
        XCTAssertEqual(meta?.capture_date, 111)
    }
}
