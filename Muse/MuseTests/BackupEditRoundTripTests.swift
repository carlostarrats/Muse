//
//  BackupEditRoundTripTests.swift
//  MuseTests
//
//  Spec 09 amendment A2 — edit data must actually ride `.muselibrary`.
//
//  Before A2 the archive carried tags + note + a content-level Sidecar and
//  nothing else, so "edit stacks survive a `.muselibrary` round-trip" failed by
//  construction. These pin the whole leg: builder reads the edit tables, the
//  archive encodes/decodes them, the applier writes them back at the NEW
//  parent_dir, and a pre-A2 archive still decodes unchanged.
//

import XCTest
import GRDB
@testable import Muse

final class BackupEditRoundTripTests: XCTestCase {

    /// A stack the codec can actually decode, so the applier derives a real
    /// hash rather than the raw-bytes fallback.
    private func stackJSON(exposure: Double) throws -> String {
        var stack = EditStack.fresh()
        stack.setTone { $0.exposureEV = exposure }
        return try EditStackCodec.encode(stack.normalized())
    }

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1', 'h1', 'image', 0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1', 'f1', '/old/Pics/cat.jpg', 1)")
        }
        return q
    }

    // MARK: - Builder

    func testBuilderCarriesStackVersionsPresetsAndLuts() async throws {
        let q = try makeQueue()
        let json = try stackJSON(exposure: 0.5)
        let lutBytes = Data([1, 2, 3, 4])
        try await q.write { db in
            try EditRecordStore.write(stackJSON: json, hash: "sh", processVersion: 1,
                                      fileID: "f1", parentDir: "/old/Pics",
                                      updatedAt: 4242, db: db)
            var v = EditVersionRow(id: "v1", file_id: "f1", parent_dir: "/old/Pics",
                                   kind: "snapshot", name: "Before",
                                   stack: json, created_at: 7)
            try v.insert(db)
            try db.execute(sql: "INSERT INTO edit_presets (id, name, stack, created_at, updated_at) VALUES ('p1', 'Warm', ?, 1, 2)",
                           arguments: [json])
            try db.execute(sql: "INSERT INTO edit_luts (id, name, size, data, created_at) VALUES ('lut-hash', 'Kodak', 2, ?, 3)",
                           arguments: [lutBytes])
        }

        let archive = try await BackupBuilder.build(
            queue: q, roots: [BackupRoot(path: "/old/Pics", display_name: "Pics")],
            createdAt: 1, appVersion: "1.0")

        let occ = try XCTUnwrap(archive.files.first?.occurrences.first)
        XCTAssertEqual(occ.edit_stack, json)
        XCTAssertEqual(occ.edit_updated_at, 4242)
        XCTAssertEqual(occ.edit_versions?.count, 1)
        XCTAssertEqual(occ.edit_versions?.first?.kind, "snapshot")
        XCTAssertEqual(occ.edit_versions?.first?.name, "Before")

        XCTAssertEqual(archive.edit_presets?.map(\.id), ["p1"])
        XCTAssertEqual(archive.edit_luts?.map(\.id), ["lut-hash"])
        // The LUT bytes must survive base64 exactly — a resampled or truncated
        // LUT is a different look under the same content hash.
        XCTAssertEqual(archive.edit_luts?.first?.data, lutBytes)
    }

    /// An unedited file must encode exactly as it did pre-A2 — no `[]`, no
    /// empty-string stack, so archives stay byte-comparable.
    func testUneditedOccurrenceCarriesNoEditFields() async throws {
        let q = try makeQueue()
        let archive = try await BackupBuilder.build(
            queue: q, roots: [BackupRoot(path: "/old/Pics", display_name: "Pics")],
            createdAt: 1, appVersion: "1.0")
        let occ = try XCTUnwrap(archive.files.first?.occurrences.first)
        XCTAssertNil(occ.edit_stack)
        XCTAssertNil(occ.edit_updated_at)
        XCTAssertNil(occ.edit_versions)
        XCTAssertNil(archive.edit_presets)
        XCTAssertNil(archive.edit_luts)
    }

    // MARK: - Archive round trip

    func testArchiveRoundTripPreservesEditData() async throws {
        let q = try makeQueue()
        let json = try stackJSON(exposure: -1.25)
        try await q.write { db in
            try EditRecordStore.write(stackJSON: json, hash: "sh", processVersion: 1,
                                      fileID: "f1", parentDir: "/old/Pics",
                                      updatedAt: 99, db: db)
            try db.execute(sql: "INSERT INTO edit_luts (id, name, size, data, created_at) VALUES ('lh', 'L', 2, ?, 3)",
                           arguments: [Data([9, 8, 7])])
        }
        let archive = try await BackupBuilder.build(
            queue: q, roots: [BackupRoot(path: "/old/Pics", display_name: "Pics")],
            createdAt: 1, appVersion: "1.0")

        let decoded = try BackupDocument.decode(BackupDocument.encode(archive))
        XCTAssertEqual(decoded, archive)
        XCTAssertEqual(decoded.files.first?.occurrences.first?.edit_stack, json)
        XCTAssertEqual(decoded.edit_luts?.first?.data, Data([9, 8, 7]))
    }

    // MARK: - Applier

    /// The restore writes the stack at the NEW parent_dir, derives the hash
    /// from the blob rather than trusting the wire, and gives versions FRESH
    /// ids.
    func testApplyMetaRestoresStackAndVersionsAtNewParentDir() async throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try await q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f9', 'h1', 'image', 0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p9', 'f9', '/new/Photos/cat.jpg', 1)")
        }
        let json = try stackJSON(exposure: 0.75)
        let expectedHash = EditStackCodec.hash(try XCTUnwrap(EditStackCodec.decode(json)))
        let occ = BackupOccurrence(
            original_path: "/old/Pics/cat.jpg", basename: "cat.jpg",
            root_path: "/old/Pics", parent_dir: "/old/Pics", tags: [],
            edit_stack: json, edit_updated_at: 555,
            edit_versions: [BackupEditVersion(kind: "version", name: "v1",
                                              stack: json, created_at: 3)])
        let meta = Sidecar(schema: 1, updated_at: 1, content_hash: "h1", kind: "image", tags: [])
        let file = BackupFile(content_hash: "h1", meta: meta, occurrences: [occ])

        try await ReconnectApplier.applyMeta(
            matches: [OccurrenceMatch(occurrence: occ, diskPath: "/new/Photos/cat.jpg",
                                      kind: .exact)],
            file: file, queue: q)

        try await q.read { db in
            let row = try XCTUnwrap(EditRecordStore.read(fileID: "f9",
                                                         parentDir: "/new/Photos", db: db))
            XCTAssertEqual(row.stack, json)
            XCTAssertEqual(row.updated_at, 555)
            XCTAssertEqual(row.stack_hash, expectedHash)   // derived, not from the wire
            let versions = try EditRecordStore.versions(fileID: "f9",
                                                        parentDir: "/new/Photos", db: db)
            XCTAssertEqual(versions.count, 1)
            XCTAssertEqual(versions[0].name, "v1")
            XCTAssertNotEqual(versions[0].id, "v1")        // fresh UUID
        }
    }

    /// A restore is an explicit recovery action, so the archive REPLACES a
    /// newer local stack — the opposite of passive sidecar hydration.
    func testRestoreWinsOverANewerLocalStack() async throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        let local = try stackJSON(exposure: 2.0)
        let archived = try stackJSON(exposure: -2.0)
        try await q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f9', 'h1', 'image', 0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p9', 'f9', '/new/P/cat.jpg', 1)")
            // Local edit is NEWER than the archive's.
            try EditRecordStore.write(stackJSON: local, hash: "lh", processVersion: 1,
                                      fileID: "f9", parentDir: "/new/P",
                                      updatedAt: 9_000, db: db)
        }
        let occ = BackupOccurrence(original_path: "/o/cat.jpg", basename: "cat.jpg",
                                   root_path: "/o", parent_dir: "/o", tags: [],
                                   edit_stack: archived, edit_updated_at: 100)
        let meta = Sidecar(schema: 1, updated_at: 1, content_hash: "h1", kind: "image", tags: [])
        try await ReconnectApplier.applyMeta(
            matches: [OccurrenceMatch(occurrence: occ, diskPath: "/new/P/cat.jpg",
                                      kind: .exact)],
            file: BackupFile(content_hash: "h1", meta: meta, occurrences: [occ]), queue: q)

        try await q.read { db in
            let row = try XCTUnwrap(EditRecordStore.read(fileID: "f9", parentDir: "/new/P", db: db))
            XCTAssertEqual(row.stack, archived)
        }
    }

    /// An occurrence with NO edit data must not delete a local edit — absence
    /// means "the backup predates this", not "reset".
    func testAbsentEditDataLeavesALocalEditAlone() async throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        let local = try stackJSON(exposure: 1.5)
        try await q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f9', 'h1', 'image', 0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p9', 'f9', '/new/P/cat.jpg', 1)")
            try EditRecordStore.write(stackJSON: local, hash: "lh", processVersion: 1,
                                      fileID: "f9", parentDir: "/new/P",
                                      updatedAt: 10, db: db)
        }
        let occ = BackupOccurrence(original_path: "/o/cat.jpg", basename: "cat.jpg",
                                   root_path: "/o", parent_dir: "/o", tags: [])
        let meta = Sidecar(schema: 1, updated_at: 1, content_hash: "h1", kind: "image", tags: [])
        try await ReconnectApplier.applyMeta(
            matches: [OccurrenceMatch(occurrence: occ, diskPath: "/new/P/cat.jpg",
                                      kind: .exact)],
            file: BackupFile(content_hash: "h1", meta: meta, occurrences: [occ]), queue: q)

        try await q.read { db in
            let row = try XCTUnwrap(EditRecordStore.read(fileID: "f9", parentDir: "/new/P", db: db))
            XCTAssertEqual(row.stack, local)
        }
    }

    // MARK: - Edit assets

    /// LUT rows are content-addressed and IMMUTABLE — a re-restore can never
    /// rewrite their bytes, and presets conflict only on their own UUID.
    func testApplyEditAssetsIsIdempotentAndNeverRewritesLutBytes() async throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try await q.write { db in
            try db.execute(sql: "INSERT INTO edit_luts (id, name, size, data, created_at) VALUES ('lh', 'Local Name', 2, ?, 1)",
                           arguments: [Data([1, 1, 1])])
        }
        let archive = BackupArchive(
            schema: 1, created_at: 0, app_version: nil, roots: [], files: [],
            collections: [], stars: [],
            edit_presets: [BackupEditPreset(id: "p1", name: "Warm", stack: "{}",
                                            created_at: 1, updated_at: 2)],
            edit_luts: [BackupLut(id: "lh", name: "Archive Name", size: 2,
                                  data: Data([9, 9, 9]))])

        let ids = try await ReconnectApplier.applyEditAssets(archive, queue: q)
        XCTAssertEqual(ids, ["lh"])
        // Re-apply: must not duplicate or mutate.
        _ = try await ReconnectApplier.applyEditAssets(archive, queue: q)

        try await q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edit_presets"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edit_luts"), 1)
            let lut = try XCTUnwrap(EditLutRow.fetchOne(db))
            XCTAssertEqual(lut.data, Data([1, 1, 1]))      // local bytes stand
            XCTAssertEqual(lut.name, "Local Name")
        }
    }

    func testApplyEditAssetsInsertsPresetsAndLutsOntoAnEmptyLibrary() async throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        let archive = BackupArchive(
            schema: 1, created_at: 0, app_version: nil, roots: [], files: [],
            collections: [], stars: [],
            edit_presets: [BackupEditPreset(id: "p1", name: "Warm", stack: "{}",
                                            created_at: 1, updated_at: 2)],
            edit_luts: [BackupLut(id: "lh", name: "Kodak", size: 2, data: Data([4, 5]))])
        _ = try await ReconnectApplier.applyEditAssets(archive, queue: q)
        try await q.read { db in
            XCTAssertEqual(try EditPresetRow.fetchOne(db)?.name, "Warm")
            XCTAssertEqual(try EditLutRow.fetchOne(db)?.data, Data([4, 5]))
        }
    }

    /// A pre-A2 archive carries none of these keys and must apply cleanly.
    func testApplyEditAssetsNoOpsOnAPreA2Archive() async throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        let archive = BackupArchive(schema: 1, created_at: 0, app_version: nil, roots: [],
                                    files: [], collections: [], stars: [])
        let ids = try await ReconnectApplier.applyEditAssets(archive, queue: q)
        XCTAssertTrue(ids.isEmpty)
    }
}
