import XCTest
import GRDB
@testable import Muse

final class PhotoStatsQueriesTests: XCTestCase {

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

    func testFeedbackInputsJoinsMetaAndTraits() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f1")
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, iso, exposure_seconds, f_number,
                                        focal_length_35mm, flash_fired)
                VALUES ('f1', 6400, 0.0625, 1.8, 85, 0)
                """)
            var traits = PhotoTraitsRow(file_id: "f1", traits_scanned_hash: "f1-hash",
                                        traits_version: PhotoTraits.currentVersion,
                                        face_count: 1, largest_face_frac: 0.4,
                                        face_quality: 0.9, pet_count: 0, sharpness: 4.0,
                                        clip_high_r: 0.01, clip_high_g: 0.005,
                                        clip_high_b: 0.006, clip_low: 0.02, noise_sigma: 3.5)
            try traits.insert(db)
        }
        let inputs = try q.read { db in try PhotoStatsQueries.feedbackInputs(fileID: "f1", db: db) }
        XCTAssertEqual(inputs?.iso, 6400)
        XCTAssertEqual(inputs?.fNumber, 1.8)
        XCTAssertEqual(inputs?.focalLength35, 85)
        XCTAssertEqual(inputs?.flashFired, false)
        XCTAssertEqual(inputs?.sharpness, 4.0)
        XCTAssertEqual(inputs?.clipHighR, 0.01)
        XCTAssertEqual(inputs?.faceCount, 1)
    }

    /// A photo with EXIF but no traits yet still deserves the notes its EXIF
    /// supports — partial data is not an error.
    func testMissingTraitsRowReturnsPartialInputs() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f3")
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, iso, exposure_seconds, f_number,
                                        focal_length_35mm, flash_fired)
                VALUES ('f3', 100, 0.01, 8, 50, 0)
                """)
        }
        let inputs = try q.read { db in try PhotoStatsQueries.feedbackInputs(fileID: "f3", db: db) }
        XCTAssertNotNil(inputs)
        XCTAssertEqual(inputs?.iso, 100)
        XCTAssertNil(inputs?.sharpness)
    }

    func testMissingMetaRowReturnsPartialInputs() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f2")
            var traits = PhotoTraitsRow(file_id: "f2", traits_scanned_hash: "f2-hash",
                                        traits_version: PhotoTraits.currentVersion,
                                        face_count: 0, largest_face_frac: nil,
                                        face_quality: nil, pet_count: 0, sharpness: 5.0,
                                        clip_high_r: 0, clip_high_g: 0, clip_high_b: 0,
                                        clip_low: 0, noise_sigma: 0.5)
            try traits.insert(db)
        }
        let inputs = try q.read { db in try PhotoStatsQueries.feedbackInputs(fileID: "f2", db: db) }
        XCTAssertNotNil(inputs)
        XCTAssertNil(inputs?.iso)
        XCTAssertEqual(inputs?.sharpness, 5.0)
    }

    /// Knowing nothing is not the same as knowing it's fine: nil renders no
    /// card at all.
    func testNoRowsAtAllReturnsNil() throws {
        let q = try makeQueue()
        try q.write { db in try insertFile(db, id: "f4") }
        let inputs = try q.read { db in try PhotoStatsQueries.feedbackInputs(fileID: "f4", db: db) }
        XCTAssertNil(inputs)
    }

    func testPathLookupResolvesThroughTheAlivePath() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f5")
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p5', 'f5', '/a/b.jpg', 1)
                """)
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, iso) VALUES ('f5', 200)
                """)
        }
        let inputs = try q.read { db in
            try PhotoStatsQueries.feedbackInputs(path: "/a/b.jpg", db: db)
        }
        XCTAssertEqual(inputs?.iso, 200)
    }
}
