//
//  DeepBackfillSelectionTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class DeepBackfillSelectionTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func insertFile(_ db: GRDB.Database, id: String, hash: String) throws {
        try db.execute(sql: """
            INSERT INTO files (id, content_hash, kind, last_seen_at)
            VALUES (?, ?, 'image', 0)
            """, arguments: [id, hash])
        try db.execute(sql: """
            INSERT INTO paths (id, file_id, absolute_path, is_alive)
            VALUES (?, ?, ?, 1)
            """, arguments: [id + "-p", id, "/tmp/\(id).jpg"])
    }

    // MARK: - traits branch

    func testMissingTraitsRowIsSelected() throws {
        let q = try makeQueue()
        try q.write { db in try insertFile(db, id: "f1", hash: "h1") }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleTraitsFileIDs(db: db, limit: 10) }
        XCTAssertEqual(ids, ["f1"])
    }

    func testStaleHashIsReselected() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f2", hash: "h2-new")
            var row = PhotoTraitsRow(file_id: "f2", traits_scanned_hash: "h2-old",
                                      traits_version: PhotoTraits.currentVersion,
                                      face_count: 0, largest_face_frac: nil,
                                      face_quality: nil, pet_count: 0, sharpness: nil)
            try row.insert(db)
        }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleTraitsFileIDs(db: db, limit: 10) }
        XCTAssertEqual(ids, ["f2"])
    }

    func testVersionBehindIsReselected() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f3", hash: "h3")
            var row = PhotoTraitsRow(file_id: "f3", traits_scanned_hash: "h3",
                                      traits_version: 0, // behind PhotoTraits.currentVersion
                                      face_count: 0, largest_face_frac: nil,
                                      face_quality: nil, pet_count: 0, sharpness: nil)
            try row.insert(db)
        }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleTraitsFileIDs(db: db, limit: 10) }
        XCTAssertEqual(ids, ["f3"])
    }

    func testUpToDateRowIsNotReselected() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f4", hash: "h4")
            var row = PhotoTraitsRow(file_id: "f4", traits_scanned_hash: "h4",
                                      traits_version: PhotoTraits.currentVersion,
                                      face_count: 0, largest_face_frac: nil,
                                      face_quality: nil, pet_count: 0, sharpness: nil)
            try row.insert(db)
        }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleTraitsFileIDs(db: db, limit: 10) }
        XCTAssertTrue(ids.isEmpty)
    }

    func testNullFieldMarkerAtCurrentHashIsNotReselected() throws {
        // An undecodable file's attempted-marker must not be retried every launch.
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "undecodable", hash: "h")
            var row = PhotoTraitsRow(file_id: "undecodable", traits_scanned_hash: "h",
                                      traits_version: PhotoTraits.currentVersion,
                                      face_count: nil, largest_face_frac: nil,
                                      face_quality: nil, pet_count: nil, sharpness: nil)
            try row.insert(db)
        }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleTraitsFileIDs(db: db, limit: 10) }
        XCTAssertTrue(ids.isEmpty)
    }

    func testDeadPathFileIsNotSelected() throws {
        let q = try makeQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f5', 'h5', 'image', 0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('f5-p', 'f5', '/tmp/f5.jpg', 0)")
        }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleTraitsFileIDs(db: db, limit: 10) }
        XCTAssertTrue(ids.isEmpty)
    }

    func testLimitIsRespected() throws {
        let q = try makeQueue()
        try q.write { db in
            for i in 0..<5 { try insertFile(db, id: "g\(i)", hash: "h\(i)") }
        }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleTraitsFileIDs(db: db, limit: 3) }
        XCTAssertEqual(ids.count, 3)
    }

    // MARK: - CLIP branch

    func testClipBranchSelectsMissingVector() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "needs-clip", hash: "h1")
            // Traits already current — must still be selected because
            // clip_embeddings is missing.
            var traits = PhotoTraitsRow(file_id: "needs-clip", traits_scanned_hash: "h1",
                                         traits_version: PhotoTraits.currentVersion,
                                         face_count: 0, largest_face_frac: nil, face_quality: nil,
                                         pet_count: 0, sharpness: nil)
            try traits.insert(db)
        }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleClipFileIDs(db: db, limit: 10) }
        XCTAssertEqual(ids, ["needs-clip"])
    }

    func testClipBranchReselectsOtherGeneration() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "old-gen", hash: "h2")
            var row = ClipEmbeddingRow(file_id: "old-gen", embedded_hash: "h2",
                                        model_generation: ClipModel.current.generation - 1,
                                        vector: ClipVectors.toData([1, 0]))
            try row.insert(db)
        }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleClipFileIDs(db: db, limit: 10) }
        XCTAssertEqual(ids, ["old-gen"])
    }

    func testClipBranchSkipsCurrentGeneration() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "current", hash: "h3")
            var row = ClipEmbeddingRow(file_id: "current", embedded_hash: "h3",
                                        model_generation: ClipModel.current.generation,
                                        vector: ClipVectors.toData([1, 0]))
            try row.insert(db)
        }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleClipFileIDs(db: db, limit: 10) }
        XCTAssertTrue(ids.isEmpty)
    }

    func testClipBranchDoesNotReselectNullVectorMarker() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "undecodable", hash: "h4")
            var row = ClipEmbeddingRow(file_id: "undecodable", embedded_hash: "h4",
                                        model_generation: ClipModel.current.generation, vector: nil)
            try row.insert(db)
        }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleClipFileIDs(db: db, limit: 10) }
        XCTAssertTrue(ids.isEmpty,
                      "a NULL-vector attempted-marker at the current generation must not be retried")
    }
}
