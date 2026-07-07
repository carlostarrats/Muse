//
//  ViewerFileDetailsNoteTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class ViewerFileDetailsNoteTests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/Pics/cat.jpg',1)")
        }
        return q
    }

    func testLoadReturnsNote() async throws {
        let q = try makeQueue()
        try await q.write { db in
            try NoteStore.write("a cat nap", fileID: "f1", parentDir: "/Pics", updatedAt: 5, db: db)
        }
        let details = try await ViewerFileDetails.load(queue: q, path: "/Pics/cat.jpg")
        XCTAssertEqual(details?.note, "a cat nap")
    }

    func testLoadReturnsEmptyWhenNoNote() async throws {
        let q = try makeQueue()
        let details = try await ViewerFileDetails.load(queue: q, path: "/Pics/cat.jpg")
        XCTAssertEqual(details?.note, "")
    }
}
