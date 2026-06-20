//
//  BackupArchiveTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class BackupArchiveTests: XCTestCase {
    private func sampleArchive() -> BackupArchive {
        let meta = Sidecar(schema: 1, updated_at: 10, content_hash: "h1", kind: "image",
                           width: 4, height: 3, duration_seconds: nil, created_at: 1,
                           modified_at: 2, caption: "a cat", dominant_color: "#fff",
                           palette: nil, feature_print: nil, analyzed_hash: "h1",
                           intent: nil, intent_model_version: nil, tags: [])
        let occ = BackupOccurrence(original_path: "/old/Pics/cat.jpg", basename: "cat.jpg",
                                   root_path: "/old/Pics", parent_dir: "/old/Pics",
                                   tags: [SidecarTag(label: "cat", source: "manual",
                                                     confidence: nil, model_version: nil)])
        return BackupArchive(
            schema: BackupArchive.currentSchema, created_at: 999, app_version: "1.0",
            roots: [BackupRoot(path: "/old/Pics", display_name: "Pics")],
            files: [BackupFile(content_hash: "h1", meta: meta, occurrences: [occ])],
            collections: [BackupCollection(id: "c1", name: "Cats", sort_order: 0,
                          model_version: "manual", is_hidden: 0, cover_hash: "h1",
                          members: [BackupMember(content_hash: "h1", added_by: "manual")],
                          excluded_hashes: [])],
            stars: [BackupStar(path: "/old/Pics/Fav", display_name: "Fav")])
    }

    func testRoundTripPreservesEverything() throws {
        let original = sampleArchive()
        let data = try BackupDocument.encode(original)
        let decoded = try BackupDocument.decode(data)
        XCTAssertEqual(decoded, original)
    }

    func testDecodeRejectsGarbage() {
        XCTAssertThrowsError(try BackupDocument.decode(Data("not json".utf8)))
    }
}
