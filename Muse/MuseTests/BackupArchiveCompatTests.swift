//
//  BackupArchiveCompatTests.swift
//  MuseTests
//
//  `.muselibrary` compatibility, pinned with RAW JSON fixtures rather than
//  round-tripped structs — a struct round trip proves the encoder agrees with
//  itself, which is exactly the thing that stays true while compatibility
//  breaks.
//
//  `BackupArchive.currentSchema` stays 1 across A2. That only holds because
//  every field added since v1 is optional-with-nil-default, so a pre-A2 archive
//  decodes into today's shape and a post-A2 archive decodes on a pre-A2 build
//  minus the new keys. If someone ever adds a REQUIRED field, these fail — and
//  that failure is the point.
//

import XCTest
@testable import Muse

final class BackupArchiveCompatTests: XCTestCase {

    /// Exactly what a pre-A2 build wrote: no edit keys anywhere.
    private let preA2 = """
    {"app_version":"1.5","collections":[],"created_at":100,"files":[{"content_hash":"h1",\
    "meta":{"content_hash":"h1","kind":"image","schema":1,"tags":[],"updated_at":10},\
    "occurrences":[{"basename":"cat.jpg","note":"hi","original_path":"/old/P/cat.jpg",\
    "parent_dir":"/old/P","root_path":"/old/P","tags":[]}]}],"roots":[],"schema":1,"stars":[]}
    """

    func testPreA2ArchiveDecodesUnchanged() throws {
        let archive = try BackupDocument.decode(Data(preA2.utf8))
        XCTAssertEqual(archive.schema, 1)
        let occ = try XCTUnwrap(archive.files.first?.occurrences.first)
        XCTAssertEqual(occ.note, "hi")
        // The new fields read as absent, not as empty values.
        XCTAssertNil(occ.edit_stack)
        XCTAssertNil(occ.edit_updated_at)
        XCTAssertNil(occ.edit_versions)
        XCTAssertNil(archive.edit_presets)
        XCTAssertNil(archive.edit_luts)
    }

    /// A pre-A2 BUILD decoding a post-A2 archive: Codable ignores unknown keys,
    /// so it gets everything it understands and silently drops the edit data.
    /// Modelled by decoding a post-A2 payload into the pre-A2 struct shape.
    func testPostA2ArchiveDecodesOnThePreA2Shape() throws {
        struct PreA2Occurrence: Codable {
            var original_path: String
            var basename: String
            var root_path: String?
            var parent_dir: String?
            var tags: [SidecarTag]
            var note: String?
        }
        struct PreA2File: Codable {
            var content_hash: String
            var meta: Sidecar
            var occurrences: [PreA2Occurrence]
        }
        struct PreA2Archive: Codable {
            var schema: Int
            var created_at: Int64
            var app_version: String?
            var roots: [BackupRoot]
            var files: [PreA2File]
            var collections: [BackupCollection]
            var stars: [BackupStar]
        }

        let meta = Sidecar(schema: 1, updated_at: 10, content_hash: "h1",
                           kind: "image", tags: [])
        let occ = BackupOccurrence(
            original_path: "/old/P/cat.jpg", basename: "cat.jpg", root_path: "/old/P",
            parent_dir: "/old/P", tags: [], note: "hi",
            edit_stack: "{\"adjustments\":[]}", edit_updated_at: 42,
            edit_versions: [BackupEditVersion(kind: "version", name: "v",
                                              stack: "{}", created_at: 1)])
        let post = BackupArchive(
            schema: 1, created_at: 100, app_version: "1.6",
            roots: [], files: [BackupFile(content_hash: "h1", meta: meta,
                                          occurrences: [occ])],
            collections: [], stars: [],
            edit_presets: [BackupEditPreset(id: "p", name: "Warm", stack: "{}",
                                            created_at: 1, updated_at: 2)],
            edit_luts: [BackupLut(id: "l", name: "K", size: 2, data: Data([1, 2]))])

        let data = try BackupDocument.encode(post)
        let old = try JSONDecoder().decode(PreA2Archive.self, from: data)
        XCTAssertEqual(old.schema, 1)                 // still readable
        XCTAssertEqual(old.files.first?.occurrences.first?.note, "hi")
        XCTAssertEqual(old.files.first?.content_hash, "h1")
    }

    /// The schema number is load-bearing for both directions above; a bump
    /// would make old builds reject new archives outright.
    func testCurrentSchemaIsStillOne() {
        XCTAssertEqual(BackupArchive.currentSchema, 1)
    }
}
