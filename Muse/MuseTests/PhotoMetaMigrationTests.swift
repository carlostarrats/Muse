//
//  PhotoMetaMigrationTests.swift
//  MuseTests
//
//  v14_photo_meta: the photo_meta table + its 7 indexes. EXIF lives in its
//  own table (not columns on files) to keep every existing SELECT * fetch
//  path lean.
//

import XCTest
import GRDB
@testable import Muse

final class PhotoMetaMigrationTests: XCTestCase {
    func testV14CreatesPhotoMetaTableAndIndexes() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.read { db in
            XCTAssertTrue(try db.tableExists("photo_meta"))
            let cols = try db.columns(in: "photo_meta").map(\.name)
            for name in ["file_id", "exif_scanned_hash", "capture_date", "capture_md",
                         "camera_make", "camera_model", "lens", "iso", "f_number",
                         "exposure_seconds", "focal_length", "focal_length_35mm",
                         "flash_fired"] {
                XCTAssertTrue(cols.contains(name), "missing column \(name)")
            }
            let indexNames = Set(try db.indexes(on: "photo_meta").map(\.name))
            for name in ["photo_meta_capture_idx", "photo_meta_md_idx",
                         "photo_meta_camera_idx", "photo_meta_lens_idx",
                         "photo_meta_iso_idx", "photo_meta_f_idx", "photo_meta_focal_idx"] {
                XCTAssertTrue(indexNames.contains(name), "missing index \(name)")
            }
        }
    }

    func testPhotoMetaCascadesOnFileDelete() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at)
                VALUES ('f1', 'hash1', 'image', 0)
                """)
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, camera_make) VALUES ('f1', 'FUJIFILM')
                """)
            try db.execute(sql: "DELETE FROM files WHERE id = 'f1'")
        }
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photo_meta") ?? -1
            XCTAssertEqual(count, 0)
        }
    }

    func testMigrationIsIdempotentAndPreservesExistingRows() throws {
        let queue = try DatabaseQueue()
        let migrator = Database.makeMigrator()
        try migrator.migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at)
                VALUES ('f1', 'hash1', 'image', 0)
                """)
        }
        try migrator.migrate(queue) // re-run: GRDB no-ops already-applied migrations
        try queue.read { db in
            let row = try FileRow.filter(FileRow.Columns.id == "f1").fetchOne(db)
            XCTAssertNotNil(row)
            XCTAssertNil(row?.lat)
            XCTAssertNil(row?.coords_scanned_hash)
            XCTAssertNil(row?.last_viewed_at)
        }
    }

    func testPhotoMetaRowRoundTrips() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at)
                VALUES ('f1', 'hash1', 'image', 0)
                """)
            var row = PhotoMetaRow(file_id: "f1", exif_scanned_hash: "hash1",
                                   capture_date: 1_561_120_200, capture_md: "06-21",
                                   camera_make: "FUJIFILM", camera_model: "X100V",
                                   lens: "23mm", iso: 400, f_number: 2.0,
                                   exposure_seconds: 0.008, focal_length: 23,
                                   focal_length_35mm: 35, flash_fired: false)
            try row.insert(db)
        }
        try queue.read { db in
            let row = try PhotoMetaRow.filter(Column("file_id") == "f1").fetchOne(db)
            XCTAssertEqual(row?.camera_model, "X100V")
            XCTAssertEqual(row?.capture_md, "06-21")
            XCTAssertEqual(row?.iso, 400)
            XCTAssertEqual(row?.flash_fired, false)
        }
    }
}
