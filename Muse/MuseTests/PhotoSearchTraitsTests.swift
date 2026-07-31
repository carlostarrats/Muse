//
//  PhotoSearchTraitsTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class PhotoSearchTraitsTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func insertFileWithTraits(_ db: GRDB.Database, id: String,
                                       faceCount: Int?, largestFrac: Double?,
                                       petCount: Int?) throws {
        try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES (?, ?, 'image', 0)",
                        arguments: [id, id + "-hash"])
        if faceCount != nil || petCount != nil {
            var row = PhotoTraitsRow(file_id: id, traits_scanned_hash: id + "-hash",
                                      traits_version: PhotoTraits.currentVersion,
                                      face_count: faceCount, largest_face_frac: largestFrac,
                                      face_quality: nil, pet_count: petCount, sharpness: nil)
            try row.insert(db)
        }
    }

    func testFacesGreaterThanFilters() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFileWithTraits(db, id: "f1", faceCount: 3, largestFrac: 0.1, petCount: 0)
            try insertFileWithTraits(db, id: "f2", faceCount: 1, largestFrac: 0.1, petCount: 0)
        }
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.faces(.init(op: .gt, value: 2))], db: db)
        }
        XCTAssertEqual(result?.idSet, ["f1"])
    }

    func testFacesZeroMatchesOnlyScannedFacelessFiles() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFileWithTraits(db, id: "scanned-zero", faceCount: 0, largestFrac: nil, petCount: 0)
            // Unscanned: no photo_traits row at all.
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('unscanned', 'h', 'image', 0)")
        }
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.faces(.init(op: .eq, value: 0))], db: db)
        }
        XCTAssertEqual(result?.idSet, ["scanned-zero"], "an unscanned file must NOT match faces:0")
    }

    func testPetsFilters() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFileWithTraits(db, id: "p1", faceCount: 0, largestFrac: nil, petCount: 2)
            try insertFileWithTraits(db, id: "p2", faceCount: 0, largestFrac: nil, petCount: 0)
        }
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.pets(.init(op: .gt, value: 0))], db: db)
        }
        XCTAssertEqual(result?.idSet, ["p1"])
    }

    func testIsPortraitFilters() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFileWithTraits(db, id: "portrait1", faceCount: 1, largestFrac: 0.2, petCount: 0)
            try insertFileWithTraits(db, id: "tiny-face", faceCount: 1, largestFrac: 0.01, petCount: 0)
            try insertFileWithTraits(db, id: "group1", faceCount: 5, largestFrac: 0.1, petCount: 0)
        }
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.traitIs(.portrait)], db: db)
        }
        XCTAssertEqual(result?.idSet, ["portrait1"])
    }

    func testIsGroupFilters() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFileWithTraits(db, id: "group1", faceCount: 4, largestFrac: 0.1, petCount: 0)
            try insertFileWithTraits(db, id: "solo1", faceCount: 1, largestFrac: 0.2, petCount: 0)
        }
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.traitIs(.group)], db: db)
        }
        XCTAssertEqual(result?.idSet, ["group1"])
    }

    func testFacesIntersectsWithKind() throws {
        // AND semantics against an existing token type.
        let q = try makeQueue()
        try q.write { db in
            try insertFileWithTraits(db, id: "img", faceCount: 3, largestFrac: 0.1, petCount: 0)
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('vid', 'vh', 'video', 0)")
            var row = PhotoTraitsRow(file_id: "vid", traits_scanned_hash: "vh",
                                      traits_version: PhotoTraits.currentVersion,
                                      face_count: 3, largest_face_frac: 0.1,
                                      face_quality: nil, pet_count: 0, sharpness: nil)
            try row.insert(db)
        }
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.faces(.init(op: .gte, value: 2)), .kind(.image)], db: db)
        }
        XCTAssertEqual(result?.idSet, ["img"])
    }
}
