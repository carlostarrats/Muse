import XCTest
import GRDB
@testable import Muse

/// v22 puts the capture statistics on the EXISTING photo_traits table and
/// bumps `PhotoTraits.currentVersion` — Spec 03's version-bump mechanism used
/// as designed, so no new marker or table is needed to get them backfilled.
final class PhotoStatsMigrationTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func insertFile(_ db: GRDB.Database, id: String) throws {
        try db.execute(sql: """
            INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES (?, ?, 'image', 0)
            """, arguments: [id, id + "-hash"])
    }

    func testV22AddsTheFiveStatColumns() throws {
        let q = try makeQueue()
        try q.read { db in
            let columns = try db.columns(in: "photo_traits").map(\.name)
            for expected in ["clip_high_r", "clip_high_g", "clip_high_b",
                             "clip_low", "noise_sigma"] {
                XCTAssertTrue(columns.contains(expected), "missing column \(expected)")
            }
        }
    }

    /// The bump is what makes every existing row version-behind, which is what
    /// DeepAnalysisBackfill selects on.
    func testCurrentVersionBumpedToTwo() {
        XCTAssertEqual(PhotoTraits.currentVersion, 2)
    }

    func testExistingTraitValuesAreUntouchedAndNewColumnsDefaultNull() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f1")
            var row = PhotoTraitsRow(file_id: "f1", traits_scanned_hash: "f1-hash",
                                     traits_version: 1, face_count: 2, largest_face_frac: 0.3,
                                     face_quality: 0.8, pet_count: 0, sharpness: 3.1,
                                     clip_high_r: nil, clip_high_g: nil, clip_high_b: nil,
                                     clip_low: nil, noise_sigma: nil)
            try row.insert(db)
        }
        let row = try q.read { db in try PhotoTraitsRow.fetchOne(db, key: "f1") }
        XCTAssertEqual(row?.face_count, 2)
        XCTAssertEqual(row?.sharpness, 3.1)
        XCTAssertNil(row?.clip_high_r)
    }

    func testANewRowCanCarryAllFiveStatColumns() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f2")
            var row = PhotoTraitsRow(file_id: "f2", traits_scanned_hash: "f2-hash",
                                     traits_version: PhotoTraits.currentVersion, face_count: 0,
                                     largest_face_frac: nil, face_quality: nil, pet_count: 0,
                                     sharpness: 2.0, clip_high_r: 0.01, clip_high_g: 0.005,
                                     clip_high_b: 0.008, clip_low: 0.0, noise_sigma: 1.4)
            try row.insert(db)
        }
        let row = try q.read { db in try PhotoTraitsRow.fetchOne(db, key: "f2") }
        XCTAssertEqual(row?.clip_high_r, 0.01)
        XCTAssertEqual(row?.noise_sigma, 1.4)
    }

    func testMigrationIsIdempotentOnReRun() throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        XCTAssertNoThrow(try Database.makeMigrator().migrate(q))
    }
}
