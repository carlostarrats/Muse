//
//  SidecarHydrateRatingTests.swift
//  MuseTests
//
//  A rating is a manual tag but is MUTUALLY EXCLUSIVE, and hydration's insert
//  only skips a tag whose EXACT label already exists — so a syncing "★★★★"
//  would land alongside a local "★★". Hydration is PASSIVE, so it yields: a
//  rating set on THIS device is never overwritten by a syncing one (the same
//  protection NoteStore.applyHydrated gives a newer local note). Deliberately
//  the opposite of restore, which is an explicit user action and replaces.
//

import XCTest
import GRDB
@testable import Muse

final class SidecarHydrateRatingTests: XCTestCase {

    private func migrated() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func seed(_ q: DatabaseQueue, localTags: [String]) throws {
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/A/x.jpg',1)")
            for (i, label) in localTags.enumerated() {
                try db.execute(sql: """
                    INSERT INTO tags (id, file_id, parent_dir, label, source, confidence)
                    VALUES (?, 'f1', '/A', ?, 'manual', NULL)
                    """, arguments: ["t\(i)", label])
            }
        }
    }

    private func sidecar(tags: [String]) -> Sidecar {
        Sidecar(schema: 1, updated_at: 100, content_hash: "h1", kind: "image",
                width: nil, height: nil, duration_seconds: nil, created_at: nil,
                modified_at: nil, caption: nil, dominant_color: nil, palette: nil,
                feature_print: nil, analyzed_hash: "h1", intent: nil,
                intent_model_version: nil,
                tags: tags.map { SidecarTag(label: $0, source: "manual",
                                            confidence: nil, model_version: nil) })
    }

    private func labels(_ q: DatabaseQueue) throws -> [String] {
        try q.read { db in
            try String.fetchAll(db, sql: "SELECT label FROM tags WHERE file_id='f1' AND parent_dir='/A'")
        }
    }

    func testSyncingRatingDoesNotJoinADifferentLocalRating() async throws {
        let q = try migrated()
        try seed(q, localTags: ["★★", "beach"])
        await SidecarHydrator.apply(sidecar(tags: ["★★★★", "dusk"]),
                                    fileID: "f1", parentDir: "/A",
                                    basename: "x.jpg", queue: q)
        let all = try labels(q)
        XCTAssertEqual(all.filter(StarRating.isRating), ["★★"],
                       "the local rating stands; the syncing one is skipped, never added")
        XCTAssertTrue(all.contains("dusk"), "ordinary syncing tags still hydrate")
        XCTAssertTrue(all.contains("beach"))
    }

    func testSyncingRatingLandsWhenTheFileHasNoneLocally() async throws {
        let q = try migrated()
        try seed(q, localTags: ["beach"])
        await SidecarHydrator.apply(sidecar(tags: ["★★★"]),
                                    fileID: "f1", parentDir: "/A",
                                    basename: "x.jpg", queue: q)
        XCTAssertEqual(try labels(q).filter(StarRating.isRating), ["★★★"])
    }

    /// A sidecar carrying two ratings (written by a build before the merge fix)
    /// must still hydrate exactly one onto a file with none.
    func testDoubleRatedSidecarHydratesOnlyOne() async throws {
        let q = try migrated()
        try seed(q, localTags: [])
        await SidecarHydrator.apply(sidecar(tags: ["★", "★★★★★"]),
                                    fileID: "f1", parentDir: "/A",
                                    basename: "x.jpg", queue: q)
        XCTAssertEqual(try labels(q).filter(StarRating.isRating), ["★★★★★"])
    }
}
