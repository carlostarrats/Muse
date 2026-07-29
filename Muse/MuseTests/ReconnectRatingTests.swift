//
//  ReconnectRatingTests.swift
//  MuseTests
//
//  Restore replaces an existing rating rather than adding a second one.
//  applyMeta's tag insert only skips a tag whose EXACT label already exists,
//  so restoring "★★★★" onto a file the user has since rated "★★" used to leave
//  it carrying both, breaking StarRating.resolution. Restore is an explicit
//  user action, so the backup's rating WINS — deliberately the opposite of
//  passive sidecar hydration, which yields to a rating already set here.
//

import XCTest
import GRDB
@testable import Muse

final class ReconnectRatingTests: XCTestCase {

    private func migrated() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func seedFile(_ q: DatabaseQueue, localTags: [(String, String)]) throws {
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/A/x.jpg',1)")
            for (i, t) in localTags.enumerated() {
                try db.execute(sql: """
                    INSERT INTO tags (id, file_id, parent_dir, label, source, confidence)
                    VALUES (?, 'f1', '/A', ?, ?, NULL)
                    """, arguments: ["t\(i)", t.0, t.1])
            }
        }
    }

    private func backupFile(occurrenceTags: [SidecarTag]) -> BackupFile {
        let meta = Sidecar(schema: 1, updated_at: 1, content_hash: "h1", kind: "image",
                           width: nil, height: nil, duration_seconds: nil, created_at: nil,
                           modified_at: nil, caption: nil, dominant_color: nil, palette: nil,
                           feature_print: nil, analyzed_hash: "h1", intent: nil,
                           intent_model_version: nil, tags: [])
        let occ = BackupOccurrence(original_path: "/Old/x.jpg", basename: "x.jpg",
                                   root_path: nil, parent_dir: "/Old",
                                   tags: occurrenceTags, note: nil)
        return BackupFile(content_hash: "h1", meta: meta, occurrences: [occ])
    }

    private func manual(_ label: String) -> SidecarTag {
        SidecarTag(label: label, source: "manual", confidence: nil, model_version: nil)
    }

    /// Sync helper: inside an async test `q.read` resolves to the ASYNC
    /// overload, so the reads live in non-async helpers (the documented GRDB
    /// overload gotcha).
    private func allLabels(_ q: DatabaseQueue) throws -> [String] {
        try q.read { db in
            try String.fetchAll(db, sql: "SELECT label FROM tags WHERE file_id='f1' AND parent_dir='/A'")
        }
    }

    private func ratings(_ q: DatabaseQueue) throws -> [String] {
        try allLabels(q).filter(StarRating.isRating).sorted()
    }

    func testRestoreReplacesAnExistingDifferentRating() async throws {
        let q = try migrated()
        try seedFile(q, localTags: [("★★", "manual"), ("beach", "vision")])
        let file = backupFile(occurrenceTags: [manual("★★★★"), manual("dusk")])
        let match = OccurrenceMatch(occurrence: file.occurrences[0],
                                    diskPath: "/A/x.jpg", kind: .exact)

        try await ReconnectApplier.applyMeta(matches: [match], file: file, queue: q)

        XCTAssertEqual(try ratings(q), ["★★★★"], "exactly one rating, the restored one")
        let all = try allLabels(q)
        XCTAssertTrue(all.contains("beach"), "unrelated local tags survive")
        XCTAssertTrue(all.contains("dusk"), "restored tags land")
    }

    func testRestoreWithoutARatingLeavesTheLocalOneAlone() async throws {
        let q = try migrated()
        try seedFile(q, localTags: [("★★★", "manual")])
        let file = backupFile(occurrenceTags: [manual("shore")])
        let match = OccurrenceMatch(occurrence: file.occurrences[0],
                                    diskPath: "/A/x.jpg", kind: .exact)

        try await ReconnectApplier.applyMeta(matches: [match], file: file, queue: q)

        XCTAssertEqual(try ratings(q), ["★★★"], "a backup with no rating must not clear one")
    }

    /// An archive written before ratings were made exclusive can carry two on
    /// one occurrence; restoring it must still land exactly one.
    func testRestoreOfADoubleRatedArchiveLandsOne() async throws {
        let q = try migrated()
        try seedFile(q, localTags: [])
        let file = backupFile(occurrenceTags: [manual("★"), manual("★★★★★")])
        let match = OccurrenceMatch(occurrence: file.occurrences[0],
                                    diskPath: "/A/x.jpg", kind: .exact)

        try await ReconnectApplier.applyMeta(matches: [match], file: file, queue: q)

        XCTAssertEqual(try ratings(q), ["★★★★★"])
    }
}
