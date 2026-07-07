//
//  ReconnectApplierTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class ReconnectApplierTests: XCTestCase {
    // Simulate the post-index state: the indexer has already created files+paths
    // for the on-disk files (by content hash). We then apply backup metadata.
    private func makeIndexedQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('nf1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('np1','nf1','/new/Pics/cat.jpg',1)")
        }
        return q
    }

    private func archive() -> BackupArchive {
        let meta = Sidecar(schema: 1, updated_at: 5, content_hash: "h1", kind: "image",
                           width: nil, height: nil, duration_seconds: nil, created_at: nil,
                           modified_at: nil, caption: "a cat", dominant_color: nil, palette: nil,
                           feature_print: nil, analyzed_hash: "h1", intent: nil,
                           intent_model_version: nil, tags: [])
        let occ = BackupOccurrence(original_path: "/old/Pics/cat.jpg", basename: "cat.jpg",
                                   root_path: "/old/Pics", parent_dir: "/old/Pics",
                                   tags: [SidecarTag(label: "cat", source: "manual",
                                                     confidence: nil, model_version: nil)],
                                   note: "a note about this cat")
        let file = BackupFile(content_hash: "h1", meta: meta, occurrences: [occ])
        let coll = BackupCollection(id: "c1", name: "Cats", sort_order: 0,
                                    model_version: "manual", is_hidden: 0, cover_hash: "h1",
                                    members: [BackupMember(content_hash: "h1", added_by: "manual")],
                                    excluded_hashes: [])
        return BackupArchive(schema: 1, created_at: 0, app_version: nil,
                             roots: [], files: [file], collections: [coll], stars: [])
    }

    func testApplyMetaWritesCaptionAndTagAtNewLocation() async throws {
        let q = try makeIndexedQueue()
        let arc = archive()
        let match = OccurrenceMatch(occurrence: arc.files[0].occurrences[0],
                                    diskPath: "/new/Pics/cat.jpg", kind: .exact)
        try await ReconnectApplier.applyMeta(matches: [match], file: arc.files[0], queue: q)

        let (caption, analyzed) = try await q.read { db -> (String?, String?) in
            let f = try FileRow.filter(FileRow.Columns.id == "nf1").fetchOne(db)!
            return (f.caption, f.analyzed_hash)
        }
        XCTAssertEqual(caption, "a cat")
        XCTAssertEqual(analyzed, "h1")
        let labels = try await q.read { db in
            try String.fetchAll(db, sql: "SELECT label FROM tags WHERE file_id='nf1' AND parent_dir='/new/Pics'")
        }
        XCTAssertEqual(labels, ["cat"])
    }

    func testApplyMetaWritesNoteAtNewLocation() async throws {
        let q = try makeIndexedQueue()
        let arc = archive()
        let match = OccurrenceMatch(occurrence: arc.files[0].occurrences[0],
                                    diskPath: "/new/Pics/cat.jpg", kind: .exact)
        try await ReconnectApplier.applyMeta(matches: [match], file: arc.files[0], queue: q)
        let note = try await q.read { db in
            try NoteStore.read(fileID: "nf1", parentDir: "/new/Pics", db: db)
        }
        XCTAssertEqual(note, "a note about this cat")
    }

    func testApplyCollectionsCreatesCollectionWithReconnectedMember() async throws {
        let q = try makeIndexedQueue()
        let arc = archive()
        let map = try await ReconnectApplier.currentFileIDForHash(queue: q)
        XCTAssertEqual(map["h1"], "nf1")
        try await ReconnectApplier.applyCollections(arc, fileIDForHash: map, queue: q)
        let loaded = try await CollectionStore.fetchAll(queue: q)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].collection.name, "Cats")
        XCTAssertEqual(loaded[0].memberIDs, ["nf1"])
    }
}
