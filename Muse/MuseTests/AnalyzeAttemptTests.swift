//
//  AnalyzeAttemptTests.swift
//  MuseTests
//
//  A file whose bytes can't be DECODED (a Fuji .RAF Apple's RAW codec doesn't
//  support — macOS itself reports no pixel dimensions for it) used to return
//  from analyzeOne without stamping analyzed_hash. That left it permanently
//  "pending": every visit to its folder re-queued it, raised the progress pill,
//  redid the futile decode and gave up. Owner-reported as a folder that does
//  that every single time. Recording the attempt is what ends the loop.
//

import XCTest
import GRDB
@testable import Muse

final class AnalyzeAttemptTests: XCTestCase {

    private func migrated() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func seed(_ q: DatabaseQueue, hash: String) throws {
        try q.write { db in
            try db.execute(sql:
                "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1',?,'raw',0)",
                arguments: [hash])
        }
    }

    private func tagCount(_ q: DatabaseQueue) throws -> Int {
        try q.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f1'") ?? 0 }
    }

    private func stampedHash(_ q: DatabaseQueue) throws -> String? {
        try q.read { db in try String.fetchOne(db, sql: "SELECT analyzed_hash FROM files WHERE id='f1'") }
    }

    private func pendingCount(_ q: DatabaseQueue) throws -> Int {
        try q.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM files
                WHERE analyzed_hash IS NULL OR analyzed_hash <> content_hash
                """) ?? 0
        }
    }

    func testUndecodableFileStopsBeingRequeued() async throws {
        let q = try migrated()
        try seed(q, hash: "h1")
        XCTAssertEqual(try pendingCount(q), 1, "starts pending")

        await AnalyzePipeline.markAnalysisAttempted(fileID: "f1", hash: "h1", queue: q)

        XCTAssertEqual(try pendingCount(q), 0,
                       "an attempted decode must not re-queue on every folder visit")
        // And it carries no tags, so explicit Regenerate can still retry it.
        XCTAssertEqual(try tagCount(q), 0)
    }

    /// If the file changed while the decode was being attempted, the stamp must
    /// NOT apply — the next pass has to read the new bytes.
    func testAttemptDoesNotStampWhenContentMovedMidPass() async throws {
        let q = try migrated()
        try seed(q, hash: "h2")
        // Vision saw h1; the row now holds h2 (re-indexed mid-pass).
        await AnalyzePipeline.markAnalysisAttempted(fileID: "f1", hash: "h1", queue: q)

        XCTAssertEqual(try pendingCount(q), 1, "still pending, so the new bytes get analyzed")
        XCTAssertNil(try stampedHash(q))
    }
}
