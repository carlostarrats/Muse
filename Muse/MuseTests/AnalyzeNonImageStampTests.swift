//
//  AnalyzeNonImageStampTests.swift
//  MuseTests
//
//  The same permanent-retry shape `AnalyzeAttemptTests` closed for an
//  UNDECODABLE image, through the neighbouring door: a kind the Vision pipeline
//  never handles at all.
//
//  `analyzeOne` returns at its kind guard for markdown / office / pdf / archive
//  without stamping `analyzed_hash`, so those rows stayed pending forever —
//  every visit to their folder re-queued them, raised the progress pill and
//  found nothing to do. Owner-reported as the pill firing on a Documents-shaped
//  folder every single time.
//
//  Stamping costs nothing and is self-repairing: an edit changes content_hash,
//  which `Indexer.reconcile` clears `analyzed_hash` for.
//

import XCTest
import GRDB
@testable import Muse

final class AnalyzeNonImageStampTests: XCTestCase {

    private func migrated() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func seed(_ q: DatabaseQueue, id: String, kind: String, hash: String) throws {
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES (?,?,?,0)
                """, arguments: [id, hash, kind])
        }
    }

    private func pending(_ q: DatabaseQueue) throws -> Set<String> {
        try q.read { db in
            try Set(String.fetchAll(db, sql: """
                SELECT id FROM files
                WHERE analyzed_hash IS NULL OR analyzed_hash <> content_hash
                """))
        }
    }

    /// The kinds that reach `analyzeOne` and fall straight out of its Vision
    /// guard. Each must end up stamped, or `analyzePending` re-queues it and
    /// raises the pill on every folder visit.
    func testKindsVisionNeverHandlesStopBeingRequeued() async throws {
        let q = try migrated()
        let kinds = ["markdown", "office", "pdf", "archive", "video"]
        for kind in kinds {
            try seed(q, id: kind, kind: kind, hash: "h-" + kind)
        }
        XCTAssertEqual(try pending(q).count, kinds.count, "all start pending")

        for kind in kinds {
            await AnalyzePipeline.stampUnanalyzableKind(fileID: kind, queue: q)
        }

        XCTAssertTrue(try pending(q).isEmpty,
                      "a kind Vision never handles must not stay pending forever")
    }

    /// The stamp is content-guarded like every other analysis write: a file
    /// re-indexed with new bytes mid-pass stays pending rather than being
    /// recorded as handled at a hash nobody looked at.
    func testStampDoesNotMarkContentItNeverSaw() async throws {
        let q = try migrated()
        try seed(q, id: "f1", kind: "pdf", hash: "old")
        // Re-indexed with new bytes between the queue read and the stamp.
        try await q.write { db in
            try db.execute(sql: "UPDATE files SET content_hash = 'new' WHERE id = 'f1'")
        }
        await AnalyzePipeline.markAnalysisAttempted(fileID: "f1", hash: "old", queue: q)
        XCTAssertEqual(try pending(q), ["f1"], "stale-hash stamp must not take")
    }
}
