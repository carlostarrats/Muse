# Library Backup & Reconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user export one self-contained backup file of their Muse library (folders, collections, tags, stars, AI metadata) and, on another Mac, restore it through a guided Reconnect wizard that re-links the data to their files by content fingerprint.

**Architecture:** A pure `BackupArchive` Codable model is assembled from the DB by `BackupBuilder` and written as a `.muselibrary` JSON file. Restore re-uses Muse's existing indexer (which already hashes every file) to populate `files`/`paths`, then a `ReconnectApplier` joins the archive to those rows **by content hash** to write metadata, tags, collection membership, and stars. A pure `ReconnectMatcher` classifies exact vs. name-only vs. unmatched, and a pure `CollectionMaterializer` enforces the "no dead collections" rule. The wizard (`ReconnectWizard`) is an `InfoSheet`-sized locked sheet driven by `ReconnectModel`.

**Tech Stack:** Swift 5.9 / SwiftUI / GRDB (SQLite) / AppKit (`NSSavePanel`/`NSOpenPanel`) / XCTest. macOS 14.6+.

## Global Constraints

- **No network.** Backup/restore is entirely local files. Never add `URLSession` or any remote call. (CLAUDE.md network policy.)
- **Files are never deleted/modified by this feature** — restore only writes to the SQLite DB and reads user files read-only (hashing). No `unlink`, no moves.
- **The live library never shows ghosts.** A collection that reconnects to zero files is not created; a partial collection shows only its connected members. "Ghost" exists only inside the wizard's accounting.
- **Reuse existing machinery:** `HashService` (SHA-256), the `Sidecar` Codable payload, `Indexer`, `AnalyzePipeline`, `CollectionStore`, `BookmarkStore`. Do not build a second hashing or analysis path.
- **GRDB writes are async** inside async contexts: `try await queue.write { }` / `try await queue.read { }`. Rows inserted as `var` (insert mutates).
- **Content hash identity:** `files.content_hash` is `UNIQUE` (one `FileRow` per content). Collection membership is keyed by the per-machine random `FileRow.id` (a UUID) — **not portable**; it must be re-keyed to `content_hash` on export and back to the new machine's `file_id` on import.
- **Tags are per `(file_id, parent_dir)`.** On restore, tags are applied at the matched file's **new** parent_dir via `Sidecar.tagRows(fileID:parentDir:makeID:)`, honoring manual-beats-vision.
- **Wizard chrome matches `InfoSheet` exactly:** `.frame(width: 600, height: 720)`, `.padding(28)`, 24pt semibold title, 15pt semibold section heads, 13pt secondary body, vertical `ScrollView`. **No `SheetCloseButton`** — a single **Cancel** button is the only dismissal; mid-run it confirms a Stop.
- **Excluded from the backup:** thumbnails (regenerate) and OCR full-text (heavy; same as today's sidecars). Everything else in §"What the export contains" of the spec is included.

Spec: `docs/superpowers/specs/2026-06-20-library-backup-and-reconnect-design.md`.

---

## File Structure

**New files:**
- `Muse/Muse/Backup/BackupArchive.swift` — pure Codable archive model (+ sub-structs). No I/O.
- `Muse/Muse/Backup/BackupBuilder.swift` — reads the DB → `BackupArchive` (re-keys membership/cover to content hash).
- `Muse/Muse/Backup/BackupDocument.swift` — encode/decode `BackupArchive` ↔ `Data` (JSON) for the `.muselibrary` file.
- `Muse/Muse/Backup/ReconnectMatcher.swift` — pure match classifier (exact / nameOnly / unmatched).
- `Muse/Muse/Backup/CollectionMaterializer.swift` — pure: which archive collections become real, with which members (hash→id), enforcing the no-dead-collection rule.
- `Muse/Muse/Backup/ReconnectApplier.swift` — DB writer: applies matched occurrences (FileRow meta + tags) and materialized collections + stars.
- `Muse/Muse/Backup/ReconnectModel.swift` — `@MainActor ObservableObject` view model: folder rows, statuses, collection readout, overall %, run/cancel.
- `Muse/Muse/Views/Backup/ReconnectWizard.swift` — the locked SwiftUI sheet.
- Tests: `Muse/MuseTests/BackupArchiveTests.swift`, `BackupBuilderTests.swift`, `ReconnectMatcherTests.swift`, `CollectionMaterializerTests.swift`, `ReconnectApplierTests.swift`.

**Modified files:**
- `Muse/Muse/MuseApp.swift` — add "Back Up Muse…" + "Restore from Backup…" menu items.
- `Muse/Muse/Models/AppState.swift` — `reconnectModel` / `reconnectShown` state + `exportBackup()` / `beginRestore(from:)`.
- `Muse/Muse/ContentView.swift` — `.sheet` presenting `ReconnectWizard`.
- `Muse/Muse/Views/InfoSheet.swift` — "Back Up & Restore" section.

---

## Task 1: Backup archive model + serialization

**Files:**
- Create: `Muse/Muse/Backup/BackupArchive.swift`
- Create: `Muse/Muse/Backup/BackupDocument.swift`
- Test: `Muse/MuseTests/BackupArchiveTests.swift`

**Interfaces:**
- Produces:
  - `struct BackupArchive: Codable, Equatable, Sendable` with `currentSchema = 1`, fields: `schema: Int`, `created_at: Int64`, `app_version: String?`, `roots: [BackupRoot]`, `files: [BackupFile]`, `collections: [BackupCollection]`, `stars: [BackupStar]`.
  - `struct BackupRoot: Codable, Equatable, Sendable { var path: String; var display_name: String }`
  - `struct BackupOccurrence: Codable, Equatable, Sendable { var original_path: String; var basename: String; var root_path: String?; var parent_dir: String?; var tags: [SidecarTag] }`
  - `struct BackupFile: Codable, Equatable, Sendable { var content_hash: String; var meta: Sidecar; var occurrences: [BackupOccurrence] }` — `meta` reuses the existing `Sidecar` for content-level fields (caption/palette/dims/intent/analyzed_hash/feature_print); its `tags` array is left empty (tags live per-occurrence).
  - `struct BackupMember: Codable, Equatable, Sendable { var content_hash: String; var added_by: String }`
  - `struct BackupCollection: Codable, Equatable, Sendable { var id: String; var name: String; var sort_order: Int; var model_version: String; var is_hidden: Int; var cover_hash: String?; var members: [BackupMember]; var excluded_hashes: [String] }`
  - `struct BackupStar: Codable, Equatable, Sendable { var path: String; var display_name: String }`
  - `enum BackupDocument { static func encode(_:) throws -> Data; static func decode(_:) throws -> BackupArchive; static let fileExtension = "muselibrary" }`

- [ ] **Step 1: Write the failing test**

```swift
//  BackupArchiveTests.swift
//  MuseTests

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/BackupArchiveTests 2>&1 | tail -20`
Expected: FAIL — "cannot find 'BackupArchive' in scope".

- [ ] **Step 3: Write the model**

```swift
//  BackupArchive.swift
//  Muse
//
//  Pure, platform-neutral model for the one-file library backup. Reuses the
//  existing Sidecar for content-level per-file metadata. Membership + cover are
//  re-keyed to content_hash here (the per-machine FileRow.id is not portable).
//

import Foundation

nonisolated struct BackupRoot: Codable, Equatable, Sendable {
    var path: String
    var display_name: String
}

nonisolated struct BackupOccurrence: Codable, Equatable, Sendable {
    var original_path: String
    var basename: String
    var root_path: String?
    var parent_dir: String?
    var tags: [SidecarTag]
}

nonisolated struct BackupFile: Codable, Equatable, Sendable {
    var content_hash: String
    var meta: Sidecar           // content-level fields; meta.tags stays empty
    var occurrences: [BackupOccurrence]
}

nonisolated struct BackupMember: Codable, Equatable, Sendable {
    var content_hash: String
    var added_by: String        // "auto" | "manual"
}

nonisolated struct BackupCollection: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var sort_order: Int
    var model_version: String
    var is_hidden: Int
    var cover_hash: String?
    var members: [BackupMember]
    var excluded_hashes: [String]
}

nonisolated struct BackupStar: Codable, Equatable, Sendable {
    var path: String
    var display_name: String
}

nonisolated struct BackupArchive: Codable, Equatable, Sendable {
    var schema: Int
    var created_at: Int64
    var app_version: String?
    var roots: [BackupRoot]
    var files: [BackupFile]
    var collections: [BackupCollection]
    var stars: [BackupStar]

    static let currentSchema = 1
}
```

```swift
//  BackupDocument.swift
//  Muse
//
//  Serializes a BackupArchive to/from the single .muselibrary file.
//

import Foundation

enum BackupDocument {
    static let fileExtension = "muselibrary"

    enum DocError: Error { case unreadable, unsupportedSchema(Int) }

    static func encode(_ archive: BackupArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }

    static func decode(_ data: Data) throws -> BackupArchive {
        let archive: BackupArchive
        do { archive = try JSONDecoder().decode(BackupArchive.self, from: data) }
        catch { throw DocError.unreadable }
        guard archive.schema == BackupArchive.currentSchema else {
            throw DocError.unsupportedSchema(archive.schema)
        }
        return archive
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/BackupArchiveTests 2>&1 | tail -20`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Backup/BackupArchive.swift Muse/Muse/Backup/BackupDocument.swift Muse/MuseTests/BackupArchiveTests.swift
git commit -m "feat: backup archive model + .muselibrary serialization"
```

---

## Task 2: Build the archive from the database

**Files:**
- Create: `Muse/Muse/Backup/BackupBuilder.swift`
- Test: `Muse/MuseTests/BackupBuilderTests.swift`

**Interfaces:**
- Consumes: `BackupArchive` and sub-structs (Task 1); `FileRow`, `PathRow`, `TagRow`, `CollectionRow`, `CollectionMemberRow`, `StarredFolderRow` (Records.swift); `TagScope.parentDir(of:)`.
- Produces: `enum BackupBuilder { static func build(queue: DatabaseQueue, roots: [BackupRoot], createdAt: Int64, appVersion: String?) async throws -> BackupArchive }`

Notes for the implementer:
- Only **alive** paths are included (`paths.is_alive = 1`). A file with no alive path is skipped (its metadata can't be reconnected to anything).
- `occurrences` are grouped per `content_hash`: one `BackupOccurrence` per alive `PathRow`, carrying that location's tags (looked up by `(file_id, parent_dir)`).
- `meta` is `Sidecar.build(from:tags:updatedAt:)` with **empty** tags (tags ride per-occurrence). If `Sidecar.build` returns nil (no content hash) skip the file.
- Collection `members`/`cover_hash`/`excluded_hashes` are re-keyed from `file_id` → that file's `content_hash`. A member whose file has no content hash is dropped.
- Include hidden collections too (so a restored Mac keeps the user's "deleted" tombstones) — `is_hidden` is carried verbatim.

- [ ] **Step 1: Write the failing test**

```swift
//  BackupBuilderTests.swift
//  MuseTests

import XCTest
import GRDB
@testable import Muse

final class BackupBuilderTests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            // One file, content hash "h1", at /old/Pics/cat.jpg
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, caption, analyzed_hash)
                VALUES ('f1', 'h1', 'image', 0, 'a cat', 'h1')""")
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1', 'f1', '/old/Pics/cat.jpg', 1)""")
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source)
                VALUES ('t1', 'f1', '/old/Pics', 'cat', 'manual')""")
            // Collection referencing f1 by id; cover f1
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, cover_file_id, sort_order)
                VALUES ('c1', 'Cats', 0, 'manual', 1, 1, 'f1', 0)""")
            try db.execute(sql: """
                INSERT INTO collection_members (collection_id, file_id, added_by)
                VALUES ('c1', 'f1', 'manual')""")
            try db.execute(sql: """
                INSERT INTO starred_folders (id, absolute_path, display_name, added_at)
                VALUES ('s1', '/old/Pics/Fav', 'Fav', 0)""")
        }
        return q
    }

    func testBuildReKeysMembershipToContentHash() async throws {
        let q = try makeQueue()
        let archive = try await BackupBuilder.build(
            queue: q, roots: [BackupRoot(path: "/old/Pics", display_name: "Pics")],
            createdAt: 123, appVersion: "1.0")

        XCTAssertEqual(archive.files.count, 1)
        let file = archive.files[0]
        XCTAssertEqual(file.content_hash, "h1")
        XCTAssertEqual(file.meta.caption, "a cat")
        XCTAssertTrue(file.meta.tags.isEmpty)                 // tags ride per-occurrence
        XCTAssertEqual(file.occurrences.count, 1)
        XCTAssertEqual(file.occurrences[0].original_path, "/old/Pics/cat.jpg")
        XCTAssertEqual(file.occurrences[0].parent_dir, "/old/Pics")
        XCTAssertEqual(file.occurrences[0].tags.map(\.label), ["cat"])

        XCTAssertEqual(archive.collections.count, 1)
        let c = archive.collections[0]
        XCTAssertEqual(c.cover_hash, "h1")                    // re-keyed from f1
        XCTAssertEqual(c.members.map(\.content_hash), ["h1"]) // re-keyed from f1
        XCTAssertEqual(archive.stars.map(\.path), ["/old/Pics/Fav"])
    }

    func testFileWithNoAlivePathIsSkipped() async throws {
        let q = try makeQueue()
        try await q.write { db in
            try db.execute(sql: "UPDATE paths SET is_alive = 0 WHERE id = 'p1'")
        }
        let archive = try await BackupBuilder.build(
            queue: q, roots: [], createdAt: 0, appVersion: nil)
        XCTAssertTrue(archive.files.isEmpty)
        // Member re-key drops f1 (no content reachable), leaving the collection empty.
        XCTAssertEqual(archive.collections.first?.members.count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/BackupBuilderTests 2>&1 | tail -20`
Expected: FAIL — "cannot find 'BackupBuilder' in scope".

- [ ] **Step 3: Write the builder**

```swift
//  BackupBuilder.swift
//  Muse
//
//  Reads the live DB and assembles a portable BackupArchive. Re-keys all
//  collection membership/cover from the per-machine FileRow.id to content_hash.
//

import Foundation
import GRDB

enum BackupBuilder {
    static func build(queue: DatabaseQueue, roots: [BackupRoot],
                      createdAt: Int64, appVersion: String?) async throws -> BackupArchive {
        try await queue.read { db in
            // file_id -> content_hash (only files that HAVE a hash)
            let fileRows = try FileRow.fetchAll(db)
            var hashByFileID: [String: String] = [:]
            var fileByID: [String: FileRow] = [:]
            for f in fileRows {
                fileByID[f.id] = f
                if let h = f.content_hash { hashByFileID[f.id] = h }
            }

            // Alive paths grouped by file_id.
            let alive = try PathRow.filter(PathRow.Columns.is_alive == 1).fetchAll(db)
            var pathsByFileID: [String: [PathRow]] = [:]
            for p in alive where p.file_id != nil {
                pathsByFileID[p.file_id!, default: []].append(p)
            }

            // Tags grouped by (file_id, parent_dir).
            let tagRows = try TagRow.fetchAll(db)
            var tagsByFileDir: [String: [SidecarTag]] = [:]   // key "file_id\u{1}parent_dir"
            for t in tagRows {
                let key = "\(t.file_id)\u{1}\(t.parent_dir ?? "")"
                tagsByFileDir[key, default: []].append(
                    SidecarTag(label: t.label, source: t.source,
                               confidence: t.confidence, model_version: t.model_version))
            }

            // Build BackupFile per content-hashed file that has >=1 alive path.
            var files: [BackupFile] = []
            for (fid, file) in fileByID {
                guard let hash = file.content_hash,
                      let paths = pathsByFileID[fid], !paths.isEmpty else { continue }
                guard let meta = Sidecar.build(from: file, tags: [], updatedAt: file.last_seen_at)
                    else { continue }
                let occurrences = paths.map { p -> BackupOccurrence in
                    let url = URL(fileURLWithPath: p.absolute_path)
                    let parent = url.deletingLastPathComponent().path
                    let rootPath = roots.first { p.absolute_path == $0.path
                        || p.absolute_path.hasPrefix($0.path + "/") }?.path
                    return BackupOccurrence(
                        original_path: p.absolute_path,
                        basename: url.lastPathComponent,
                        root_path: rootPath,
                        parent_dir: parent,
                        tags: tagsByFileDir["\(fid)\u{1}\(parent)"] ?? [])
                }
                files.append(BackupFile(content_hash: hash, meta: meta, occurrences: occurrences))
            }
            files.sort { $0.content_hash < $1.content_hash }

            // Collections, members/cover/exclusions re-keyed to content_hash.
            let collRows = try CollectionRow.fetchAll(db)
            var collections: [BackupCollection] = []
            for c in collRows {
                let memberRows = try CollectionMemberRow
                    .filter(Column("collection_id") == c.id).fetchAll(db)
                let members = memberRows.compactMap { m -> BackupMember? in
                    guard let h = hashByFileID[m.file_id] else { return nil }
                    return BackupMember(content_hash: h, added_by: m.added_by)
                }
                let excluded = try String.fetchAll(db, sql:
                    "SELECT file_id FROM collection_exclusions WHERE collection_id = ?",
                    arguments: [c.id]).compactMap { hashByFileID[$0] }
                let coverHash = c.cover_file_id.flatMap { hashByFileID[$0] }
                collections.append(BackupCollection(
                    id: c.id, name: c.name, sort_order: c.sort_order,
                    model_version: c.model_version, is_hidden: c.is_hidden,
                    cover_hash: coverHash, members: members, excluded_hashes: excluded))
            }

            let starRows = try StarredFolderRow.fetchAll(db)
            let stars = starRows.map { BackupStar(path: $0.absolute_path, display_name: $0.display_name) }

            return BackupArchive(
                schema: BackupArchive.currentSchema, created_at: createdAt,
                app_version: appVersion, roots: roots, files: files,
                collections: collections, stars: stars)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/BackupBuilderTests 2>&1 | tail -20`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Backup/BackupBuilder.swift Muse/MuseTests/BackupBuilderTests.swift
git commit -m "feat: build portable backup archive from the DB (content-hash re-key)"
```

---

## Task 3: Pure reconnect matcher (exact / name-only / unmatched)

**Files:**
- Create: `Muse/Muse/Backup/ReconnectMatcher.swift`
- Test: `Muse/MuseTests/ReconnectMatcherTests.swift`

**Interfaces:**
- Consumes: `BackupOccurrence` (Task 1).
- Produces:
  - `struct DiskFile: Equatable, Sendable { var path: String; var basename: String; var contentHash: String? }` — a file the indexer already hashed.
  - `enum MatchKind: Equatable, Sendable { case exact, nameOnly }`
  - `struct OccurrenceMatch: Equatable, Sendable { var occurrence: BackupOccurrence; var diskPath: String; var kind: MatchKind }`
  - `struct MatchResult: Equatable, Sendable { var matches: [OccurrenceMatch]; var unmatched: [BackupOccurrence] }`
  - `enum ReconnectMatcher { static func match(occurrences: [BackupOccurrence], disk: [DiskFile], expectedHash: [String: String]) -> MatchResult }`
    - `expectedHash` maps `occurrence.original_path` → that occurrence's content_hash (the caller has it; the occurrence struct intentionally doesn't store its own hash). The matcher uses it to pair an occurrence with a disk file by hash first, then by basename.

Matching rules (within a single folder's scan):
1. **Exact:** an unused disk file whose `contentHash` equals the occurrence's expected hash. Consume it.
2. **Name-only:** else an unused disk file whose `basename` equals the occurrence's `basename`. Mark `.nameOnly`.
3. Else the occurrence is `unmatched`.
A disk file is consumed by at most one occurrence (no double-use). Exact matches are resolved for ALL occurrences before any name-only fallback, so a name collision can't steal a file that an exact match needs.

- [ ] **Step 1: Write the failing test**

```swift
//  ReconnectMatcherTests.swift
//  MuseTests

import XCTest
@testable import Muse

final class ReconnectMatcherTests: XCTestCase {
    private func occ(_ path: String, _ name: String) -> BackupOccurrence {
        BackupOccurrence(original_path: path, basename: name, root_path: nil,
                         parent_dir: nil, tags: [])
    }

    func testExactHashWinsEvenIfRenamed() {
        let o = occ("/old/cat.jpg", "cat.jpg")
        let disk = [DiskFile(path: "/new/renamed.jpg", basename: "renamed.jpg", contentHash: "h1")]
        let r = ReconnectMatcher.match(occurrences: [o], disk: disk,
                                       expectedHash: ["/old/cat.jpg": "h1"])
        XCTAssertEqual(r.matches, [OccurrenceMatch(occurrence: o, diskPath: "/new/renamed.jpg", kind: .exact)])
        XCTAssertTrue(r.unmatched.isEmpty)
    }

    func testNameOnlyFallbackWhenBytesChanged() {
        let o = occ("/old/cat.jpg", "cat.jpg")
        let disk = [DiskFile(path: "/new/cat.jpg", basename: "cat.jpg", contentHash: "DIFFERENT")]
        let r = ReconnectMatcher.match(occurrences: [o], disk: disk,
                                       expectedHash: ["/old/cat.jpg": "h1"])
        XCTAssertEqual(r.matches.first?.kind, .nameOnly)
        XCTAssertEqual(r.matches.first?.diskPath, "/new/cat.jpg")
    }

    func testUnmatchedWhenNeitherHashNorName() {
        let o = occ("/old/cat.jpg", "cat.jpg")
        let disk = [DiskFile(path: "/new/dog.png", basename: "dog.png", contentHash: "zzz")]
        let r = ReconnectMatcher.match(occurrences: [o], disk: disk,
                                       expectedHash: ["/old/cat.jpg": "h1"])
        XCTAssertTrue(r.matches.isEmpty)
        XCTAssertEqual(r.unmatched, [o])
    }

    func testExactResolvedBeforeNameFallbackSoNoFileTheft() {
        // o1 needs hash h1 (file is named "other.jpg" now); o2 is name-only "cat.jpg".
        let o1 = occ("/old/cat.jpg", "cat.jpg")          // expects h1
        let o2 = occ("/old/copy/cat.jpg", "cat.jpg")     // expects h2 (not on disk)
        let disk = [
            DiskFile(path: "/new/other.jpg", basename: "other.jpg", contentHash: "h1"),
            DiskFile(path: "/new/cat.jpg", basename: "cat.jpg", contentHash: "h1"),
        ]
        let r = ReconnectMatcher.match(
            occurrences: [o1, o2], disk: disk,
            expectedHash: ["/old/cat.jpg": "h1", "/old/copy/cat.jpg": "h2"])
        // o1 took an exact h1 file; o2 falls back to the remaining name match "cat.jpg".
        XCTAssertEqual(r.matches.count, 2)
        XCTAssertEqual(r.matches.first { $0.occurrence == o1 }?.kind, .exact)
        XCTAssertEqual(r.matches.first { $0.occurrence == o2 }?.kind, .nameOnly)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/ReconnectMatcherTests 2>&1 | tail -20`
Expected: FAIL — "cannot find 'ReconnectMatcher' in scope".

- [ ] **Step 3: Write the matcher**

```swift
//  ReconnectMatcher.swift
//  Muse
//
//  Pure classifier mapping backup occurrences onto on-disk files the indexer
//  already hashed. Exact (content hash) first, filename second, else unmatched.
//

import Foundation

nonisolated struct DiskFile: Equatable, Sendable {
    var path: String
    var basename: String
    var contentHash: String?
}

nonisolated enum MatchKind: Equatable, Sendable { case exact, nameOnly }

nonisolated struct OccurrenceMatch: Equatable, Sendable {
    var occurrence: BackupOccurrence
    var diskPath: String
    var kind: MatchKind
}

nonisolated struct MatchResult: Equatable, Sendable {
    var matches: [OccurrenceMatch]
    var unmatched: [BackupOccurrence]
}

nonisolated enum ReconnectMatcher {
    static func match(occurrences: [BackupOccurrence], disk: [DiskFile],
                      expectedHash: [String: String]) -> MatchResult {
        var consumed = Set<String>()                 // disk paths already taken
        var matches: [OccurrenceMatch] = []
        var stillOpen: [BackupOccurrence] = []

        // Index disk files by hash and by basename for O(1) pick.
        var byHash: [String: [DiskFile]] = [:]
        var byName: [String: [DiskFile]] = [:]
        for d in disk {
            if let h = d.contentHash { byHash[h, default: []].append(d) }
            byName[d.basename, default: []].append(d)
        }

        // Pass 1: exact hash matches for every occurrence first.
        for o in occurrences {
            guard let want = expectedHash[o.original_path],
                  let candidates = byHash[want] else { stillOpen.append(o); continue }
            if let pick = candidates.first(where: { !consumed.contains($0.path) }) {
                consumed.insert(pick.path)
                matches.append(OccurrenceMatch(occurrence: o, diskPath: pick.path, kind: .exact))
            } else {
                stillOpen.append(o)
            }
        }

        // Pass 2: name-only fallback for whatever's left.
        var unmatched: [BackupOccurrence] = []
        for o in stillOpen {
            if let candidates = byName[o.basename],
               let pick = candidates.first(where: { !consumed.contains($0.path) }) {
                consumed.insert(pick.path)
                matches.append(OccurrenceMatch(occurrence: o, diskPath: pick.path, kind: .nameOnly))
            } else {
                unmatched.append(o)
            }
        }
        return MatchResult(matches: matches, unmatched: unmatched)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/ReconnectMatcherTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Backup/ReconnectMatcher.swift Muse/MuseTests/ReconnectMatcherTests.swift
git commit -m "feat: pure reconnect matcher (exact hash, filename fallback)"
```

---

## Task 4: Pure collection materializer (no dead collections)

**Files:**
- Create: `Muse/Muse/Backup/CollectionMaterializer.swift`
- Test: `Muse/MuseTests/CollectionMaterializerTests.swift`

**Interfaces:**
- Consumes: `BackupCollection`, `BackupMember` (Task 1).
- Produces:
  - `struct MaterializedCollection: Equatable, Sendable { var id: String; var name: String; var sortOrder: Int; var modelVersion: String; var isHidden: Int; var coverFileID: String?; var memberFileIDs: [(fileID: String, addedBy: String)]; var excludedFileIDs: [String] }`
    - Note: tuples aren't `Equatable` automatically; for the test, expose `memberFileIDs` as `[MaterializedMember]` where `struct MaterializedMember: Equatable, Sendable { var fileID: String; var addedBy: String }`.
  - `enum CollectionMaterializer { static func materialize(_ collections: [BackupCollection], fileIDForHash: [String: String]) -> [MaterializedCollection] }`

Rules:
- Re-key each member/cover/exclusion `content_hash` → `file_id` via `fileIDForHash`. A member whose hash didn't reconnect (absent from the map) is dropped.
- A collection with **zero** resolved members is **dropped** UNLESS `model_version == "manual"` (a deliberately hand-made collection is preserved even when empty).
- Carry `is_hidden`, `sort_order`, `name`, `model_version` verbatim; resolve `cover_file_id` only if its hash reconnected (else nil = auto).

- [ ] **Step 1: Write the failing test**

```swift
//  CollectionMaterializerTests.swift
//  MuseTests

import XCTest
@testable import Muse

final class CollectionMaterializerTests: XCTestCase {
    private func coll(_ id: String, _ model: String, members: [String], cover: String? = nil)
        -> BackupCollection {
        BackupCollection(id: id, name: id, sort_order: 0, model_version: model,
                         is_hidden: 0, cover_hash: cover,
                         members: members.map { BackupMember(content_hash: $0, added_by: "auto") },
                         excluded_hashes: [])
    }

    func testAutoEmptyCollectionDropped() {
        let result = CollectionMaterializer.materialize(
            [coll("c1", "v1", members: ["h_missing"])],
            fileIDForHash: [:])               // nothing reconnected
        XCTAssertTrue(result.isEmpty)
    }

    func testManualEmptyCollectionPreserved() {
        let result = CollectionMaterializer.materialize(
            [coll("c1", "manual", members: [])],
            fileIDForHash: [:])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].memberFileIDs.isEmpty)
    }

    func testPartialCollectionKeepsOnlyReconnectedMembers() {
        let result = CollectionMaterializer.materialize(
            [coll("c1", "v1", members: ["h1", "h2", "h3"], cover: "h2")],
            fileIDForHash: ["h1": "f1", "h3": "f3"])   // h2 missing
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].memberFileIDs.map(\.fileID).sorted(), ["f1", "f3"])
        XCTAssertNil(result[0].coverFileID)            // cover h2 didn't reconnect
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/CollectionMaterializerTests 2>&1 | tail -20`
Expected: FAIL — "cannot find 'CollectionMaterializer' in scope".

- [ ] **Step 3: Write the materializer**

```swift
//  CollectionMaterializer.swift
//  Muse
//
//  Pure rules turning archived collections into the rows we actually create on
//  restore. Enforces "no dead collections": an auto collection with zero
//  reconnected members is dropped; a hand-made (manual) one is kept even empty.
//

import Foundation

nonisolated struct MaterializedMember: Equatable, Sendable {
    var fileID: String
    var addedBy: String
}

nonisolated struct MaterializedCollection: Equatable, Sendable {
    var id: String
    var name: String
    var sortOrder: Int
    var modelVersion: String
    var isHidden: Int
    var coverFileID: String?
    var memberFileIDs: [MaterializedMember]
    var excludedFileIDs: [String]
}

nonisolated enum CollectionMaterializer {
    static func materialize(_ collections: [BackupCollection],
                            fileIDForHash: [String: String]) -> [MaterializedCollection] {
        var out: [MaterializedCollection] = []
        for c in collections {
            let members = c.members.compactMap { m -> MaterializedMember? in
                guard let fid = fileIDForHash[m.content_hash] else { return nil }
                return MaterializedMember(fileID: fid, addedBy: m.added_by)
            }
            let isManual = c.model_version == "manual"
            if members.isEmpty && !isManual { continue }    // drop dead auto collection
            out.append(MaterializedCollection(
                id: c.id, name: c.name, sortOrder: c.sort_order,
                modelVersion: c.model_version, isHidden: c.is_hidden,
                coverFileID: c.cover_hash.flatMap { fileIDForHash[$0] },
                memberFileIDs: members,
                excludedFileIDs: c.excluded_hashes.compactMap { fileIDForHash[$0] }))
        }
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/CollectionMaterializerTests 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Backup/CollectionMaterializer.swift Muse/MuseTests/CollectionMaterializerTests.swift
git commit -m "feat: pure collection materializer (no dead collections rule)"
```

---

## Task 5: Reconnect applier (DB writer)

**Files:**
- Create: `Muse/Muse/Backup/ReconnectApplier.swift`
- Test: `Muse/MuseTests/ReconnectApplierTests.swift`

**Interfaces:**
- Consumes: `BackupArchive`, `OccurrenceMatch`, `MatchKind` (Tasks 1, 3); `MaterializedCollection`, `CollectionMaterializer` (Task 4); `Sidecar.apply`, `Sidecar.tagRows`; `FileRow`, `PathRow`, `TagRow`, `CollectionRow`, `CollectionMemberRow`, `StarredFolderRow`.
- Produces:
  - `enum ReconnectApplier {`
    - `static func applyMeta(matches: [OccurrenceMatch], file: BackupFile, queue: DatabaseQueue) async throws` — for each matched disk path: ensure the `paths` row resolves to a `file_id`, apply `file.meta` onto that `FileRow`, write the occurrence's tags at the disk file's parent_dir. (Assumes the indexer already created `files`/`paths` rows for the disk files; this only enriches them.)
    - `static func applyCollections(_ archive: BackupArchive, fileIDForHash: [String: String], queue: DatabaseQueue) async throws` — materialize + write `collections`, `collection_members`, `collection_exclusions`, preserving `is_hidden`/`sort_order`/cover.
    - `static func applyStars(_ archive: BackupArchive, queue: DatabaseQueue) async throws` — insert `starred_folders` (ignore conflicts) for paths that exist on disk.
    - `static func currentFileIDForHash(queue: DatabaseQueue) async throws -> [String: String]` — `content_hash` → `files.id` for all hashed files (the map handed to `applyCollections`).`}`

Implementer notes:
- `applyMeta` resolves the `file_id` for a disk path via the `paths` table (alive). If the path isn't indexed yet, skip it (the indexer will create it; meta is applied on a later pass — but in practice the engine indexes before applying, so it's present).
- Tag application mirrors `SidecarHydrator.apply` exactly (manual-beats-vision per `(file_id, parent_dir)`), but uses the **occurrence's** tags and the **disk** parent_dir.
- `applyCollections` deletes existing members for the collection id then re-inserts (collections are keyed by their original archive id, stable across machines).

- [ ] **Step 1: Write the failing test**

```swift
//  ReconnectApplierTests.swift
//  MuseTests

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
            // Disk file at /new/Pics/cat.jpg, hash h1, indexed but NOT analyzed.
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
                                                     confidence: nil, model_version: nil)])
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
        XCTAssertEqual(analyzed, "h1")          // marked analyzed → no re-Vision
        let labels = try await q.read { db in
            try String.fetchAll(db, sql:
                "SELECT label FROM tags WHERE file_id='nf1' AND parent_dir='/new/Pics'")
        }
        XCTAssertEqual(labels, ["cat"])         // tag re-keyed to the NEW parent_dir
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/ReconnectApplierTests 2>&1 | tail -20`
Expected: FAIL — "cannot find 'ReconnectApplier' in scope".

- [ ] **Step 3: Write the applier**

```swift
//  ReconnectApplier.swift
//  Muse
//
//  Writes backup metadata onto the rows the indexer already created (joined by
//  content hash / disk path), then materializes collections + stars. The live
//  library only ever gains REAL, reconnected files — never ghosts.
//

import Foundation
import GRDB

enum ReconnectApplier {
    /// content_hash -> files.id for every hashed file currently in the DB.
    static func currentFileIDForHash(queue: DatabaseQueue) async throws -> [String: String] {
        try await queue.read { db in
            var map: [String: String] = [:]
            for f in try FileRow.fetchAll(db) where f.content_hash != nil {
                map[f.content_hash!] = f.id
            }
            return map
        }
    }

    static func applyMeta(matches: [OccurrenceMatch], file: BackupFile,
                          queue: DatabaseQueue) async throws {
        for m in matches {
            let url = URL(fileURLWithPath: m.diskPath)
            let parentDir = url.deletingLastPathComponent().path
            let basename = url.lastPathComponent
            try await queue.write { db in
                guard let path = try PathRow
                        .filter(PathRow.Columns.absolute_path == m.diskPath)
                        .filter(PathRow.Columns.is_alive == 1).fetchOne(db),
                      let fid = path.file_id,
                      var fileRow = try FileRow.filter(FileRow.Columns.id == fid).fetchOne(db)
                else { return }
                file.meta.apply(onto: &fileRow)
                try fileRow.update(db)
                // Tags: occurrence's tags at the NEW parent_dir (manual beats vision).
                for t in tagRows(from: m.occurrence.tags, fileID: fid, parentDir: parentDir) {
                    if let existing = try TagRow
                        .filter(TagRow.Columns.file_id == fid)
                        .filter(TagRow.Columns.parent_dir == parentDir)
                        .filter(TagRow.Columns.label == t.label).fetchOne(db) {
                        if existing.source != "manual" && t.source == "manual" {
                            var u = existing; u.source = "manual"; u.confidence = nil
                            u.model_version = nil; try u.update(db)
                        }
                    } else {
                        var row = t; try row.insert(db)
                    }
                }
                // FTS mirror (basename + caption; OCR intentionally empty — same as hydrate).
                try db.execute(sql: "DELETE FROM files_fts WHERE file_id = ?", arguments: [fid])
                try db.execute(sql: """
                    INSERT INTO files_fts(file_id, basename, ocr_text, caption)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [fid, basename, "", file.meta.caption ?? ""])
            }
        }
    }

    private static func tagRows(from tags: [SidecarTag], fileID: String,
                                parentDir: String) -> [TagRow] {
        tags.map {
            TagRow(id: UUID().uuidString, file_id: fileID, parent_dir: parentDir,
                   label: $0.label, source: $0.source, confidence: $0.confidence,
                   model_version: $0.model_version)
        }
    }

    static func applyCollections(_ archive: BackupArchive, fileIDForHash: [String: String],
                                 queue: DatabaseQueue) async throws {
        let materialized = CollectionMaterializer.materialize(archive.collections,
                                                              fileIDForHash: fileIDForHash)
        let now = Int64(Date().timeIntervalSince1970)
        try await queue.write { db in
            for c in materialized {
                try db.execute(sql: """
                    INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, cover_file_id, sort_order)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name,
                        is_hidden = excluded.is_hidden, model_version = excluded.model_version,
                        cover_file_id = excluded.cover_file_id, sort_order = excluded.sort_order,
                        updated_at = excluded.updated_at
                    """, arguments: [c.id, c.name, c.isHidden, c.modelVersion, now, now,
                                     c.coverFileID, c.sortOrder])
                try db.execute(sql: "DELETE FROM collection_members WHERE collection_id = ?",
                               arguments: [c.id])
                for m in c.memberFileIDs {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO collection_members (collection_id, file_id, added_by)
                        VALUES (?, ?, ?)
                        """, arguments: [c.id, m.fileID, m.addedBy])
                }
                try db.execute(sql: "DELETE FROM collection_exclusions WHERE collection_id = ?",
                               arguments: [c.id])
                for ex in c.excludedFileIDs {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO collection_exclusions (collection_id, file_id)
                        VALUES (?, ?)
                        """, arguments: [c.id, ex])
                }
            }
        }
    }

    static func applyStars(_ archive: BackupArchive, queue: DatabaseQueue) async throws {
        let fm = FileManager.default
        try await queue.write { db in
            for s in archive.stars where fm.fileExists(atPath: s.path) {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO starred_folders (id, absolute_path, display_name, added_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, s.path, s.display_name,
                                     Int64(Date().timeIntervalSince1970)])
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/ReconnectApplierTests 2>&1 | tail -20`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Backup/ReconnectApplier.swift Muse/MuseTests/ReconnectApplierTests.swift
git commit -m "feat: reconnect applier writes metadata, tags, collections, stars"
```

---

## Task 6: Export — "Back Up Muse…" menu command + save panel

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift` (add `exportBackup()`)
- Modify: `Muse/Muse/MuseApp.swift` (add the menu item)

**Interfaces:**
- Consumes: `BackupBuilder.build` (Task 2), `BackupDocument.encode` (Task 1), `bookmarks.roots`, `Database.shared.dbQueue`.
- Produces: `AppState.exportBackup()` (runs the save panel + writes the file).

Implementer notes:
- Roots for the archive come from the live sidebar roots. Build `[BackupRoot]` from `bookmarks.roots` (resolve each to a URL + display name). Use the resolved standardized path.
- App version: `Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String`.
- The save panel default name: `"Muse Backup \(yyyy-MM-dd).muselibrary"`.
- No test (AppKit panel + I/O; the testable core is Tasks 1–2). Verify by build + manual run.

- [ ] **Step 1: Add `exportBackup()` to AppState**

Add near the other folder/command methods in `AppState.swift`:

```swift
    /// Export a one-file backup of the whole library (folders, collections,
    /// tags, stars, AI metadata) re-keyed to content hash. See the 2026-06-20
    /// library-backup spec. Purely additive; reads the DB, writes a file.
    func exportBackup() {
        guard let queue = Database.shared.dbQueue else { return }
        // Snapshot roots on the main actor.
        let roots: [BackupRoot] = bookmarks.roots.compactMap { root in
            guard let url = bookmarks.url(for: root) else { return nil }
            return BackupRoot(path: url.standardizedFileURL.path,
                              display_name: url.lastPathComponent)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let suggested = "Muse Backup \(formatter.string(from: Date())).\(BackupDocument.fileExtension)"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.canCreateDirectories = true
        panel.message = "Keep this file somewhere safe — ideally not only on this Mac. "
            + "You'll use it to restore your collections, tags, and folders on another Mac."
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        Task {
            do {
                let archive = try await BackupBuilder.build(
                    queue: queue, roots: roots,
                    createdAt: Int64(Date().timeIntervalSince1970), appVersion: version)
                let data = try BackupDocument.encode(archive)
                try data.write(to: dest, options: .atomic)
            } catch {
                print("[Backup] export failed: \(error)")
            }
        }
    }
```

Ensure `import AppKit` is present in AppState.swift (it already imports AppKit for other panels; if not, add it).

- [ ] **Step 2: Add the menu item in MuseApp.swift**

In the `CommandGroup(after: .appInfo)` block (currently holding `CheckForUpdatesView`), add the two backup items below it so they sit in the Muse app menu:

```swift
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater.controller.updater)
                Divider()
                Button("Back Up Muse…") { appState.exportBackup() }
                Button("Restore from Backup…") { appState.beginRestorePicker() }
            }
```

(`beginRestorePicker()` is added in Task 8; to keep this task compiling on its own, temporarily stub it as `func beginRestorePicker() {}` in AppState now — Task 8 replaces the body.)

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual smoke test**

Run the app, add a folder, let it index, then **Muse ▸ Back Up Muse…**, save to Desktop. Confirm a `.muselibrary` file is written and is human-readable JSON (`head` it). Expected: a JSON file with `roots`, `files`, `collections`.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Models/AppState.swift Muse/Muse/MuseApp.swift
git commit -m "feat: Back Up Muse menu command + save panel"
```

---

## Task 7: Reconnect model (orchestration state machine)

**Files:**
- Create: `Muse/Muse/Backup/ReconnectModel.swift`

**Interfaces:**
- Consumes: `BackupArchive`, `ReconnectMatcher`, `ReconnectApplier`, `DiskFile`, `HashService.sha256`, `BookmarkStore`, `Database.shared.dbQueue`, `AnalyzePipeline.shared`.
- Produces: `@MainActor final class ReconnectModel: ObservableObject` with:
  - `enum FolderStatus { case pending, working, clean, flagged(unmatched: Int) }`
  - `struct FolderRow: Identifiable { let id: String /* root_path */; let displayName: String; var newLocation: URL?; var status: FolderStatus }`
  - `struct CollectionStatusRow: Identifiable { let id: String; let name: String; var reconnected: Int; var total: Int }`
  - `@Published var folders: [FolderRow]`
  - `@Published var collectionStatuses: [CollectionStatusRow]`
  - `@Published var isRunning: Bool`
  - `@Published var finished: Bool`
  - `var overallPercent: Int` (computed: reconnected members / total members across collections, 0 if none)
  - `init(archive: BackupArchive)`
  - `func autoMap(parent: URL)` — point at one parent; map each root to a same-named subdirectory if present.
  - `func setLocation(_ url: URL, forFolder id: String)`
  - `func reconnectAll(bookmarks: BookmarkStore) async` — the batch runner.
  - `func cancel()`

Design (concrete):
- `reconnectAll` iterates folders that have a `newLocation`. For each: set `.working`; add the location as a root via `bookmarks.addRoot(at:)`; enumerate its files; compute `DiskFile`s (path, basename, `HashService.sha256`); build `expectedHash` for the archive occurrences whose `root_path == folder.id`; call `ReconnectMatcher.match`; for each matched occurrence look up its `BackupFile` and call `ReconnectApplier.applyMeta`; set status `.clean` if `unmatched.isEmpty` else `.flagged(unmatched.count)`.
- After all folders: `let map = try await ReconnectApplier.currentFileIDForHash(queue:)`; `try await ReconnectApplier.applyCollections(archive, fileIDForHash: map, queue:)`; `try await ReconnectApplier.applyStars(archive, queue:)`; recompute `collectionStatuses` from `map` (reconnected = members whose hash is in `map`); kick `AnalyzePipeline.shared.analyzePending(in:)` over the newly added image URLs (reconcile new/changed files); set `finished = true`, `isRunning = false`.
- `cancel()` sets a flag the loop checks between folders and flips `isRunning = false`.

Implementer notes:
- Build a `hashToFile: [String: BackupFile]` and `occurrencesByRoot: [String: [BackupOccurrence]]` once in `init`.
- `expectedHash[occurrence.original_path] = <that file's content_hash>` — derive from `hashToFile` by scanning each file's occurrences in `init` into `hashForOriginalPath: [String: String]`.
- This class is integration-level (filesystem + DB); it is not unit-tested (consistent with the project's "UI/integration views aren't unit-tested" stance — its logic is the already-tested matcher/materializer/applier). Verified via the manual round-trip in Task 9.

- [ ] **Step 1: Write the model**

```swift
//  ReconnectModel.swift
//  Muse
//
//  Drives the Reconnect wizard. Maps each backed-up folder to a new location,
//  then (on Reconnect All) indexes + hashes each, matches occurrences by
//  content hash, applies metadata, and finally materializes collections + stars.
//  All heavy lifting delegates to the pure matcher/materializer/applier.
//

import Foundation
import SwiftUI

@MainActor
final class ReconnectModel: ObservableObject {
    enum FolderStatus: Equatable {
        case pending, working, clean, flagged(unmatched: Int)
    }
    struct FolderRow: Identifiable {
        let id: String              // original root_path
        let displayName: String
        var newLocation: URL?
        var status: FolderStatus
    }
    struct CollectionStatusRow: Identifiable {
        let id: String
        let name: String
        var reconnected: Int
        var total: Int
    }

    @Published var folders: [FolderRow]
    @Published var collectionStatuses: [CollectionStatusRow]
    @Published var isRunning = false
    @Published var finished = false

    private let archive: BackupArchive
    private let hashToFile: [String: BackupFile]
    private let hashForOriginalPath: [String: String]
    private var cancelled = false

    var overallPercent: Int {
        let total = collectionStatuses.reduce(0) { $0 + $1.total }
        guard total > 0 else { return 0 }
        let done = collectionStatuses.reduce(0) { $0 + $1.reconnected }
        return Int((Double(done) / Double(total) * 100).rounded())
    }

    init(archive: BackupArchive) {
        self.archive = archive
        var byHash: [String: BackupFile] = [:]
        var hashForPath: [String: String] = [:]
        for f in archive.files {
            byHash[f.content_hash] = f
            for o in f.occurrences { hashForPath[o.original_path] = f.content_hash }
        }
        self.hashToFile = byHash
        self.hashForOriginalPath = hashForPath
        self.folders = archive.roots.map {
            FolderRow(id: $0.path, displayName: $0.display_name, newLocation: nil, status: .pending)
        }
        self.collectionStatuses = archive.collections
            .filter { $0.is_hidden == 0 }
            .map { CollectionStatusRow(id: $0.id, name: $0.name,
                                       reconnected: 0, total: $0.members.count) }
    }

    func autoMap(parent: URL) {
        let fm = FileManager.default
        for i in folders.indices {
            let candidate = parent.appendingPathComponent(folders[i].displayName, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                folders[i].newLocation = candidate
            }
        }
    }

    func setLocation(_ url: URL, forFolder id: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].newLocation = url
    }

    func cancel() {
        cancelled = true
        isRunning = false
    }

    func reconnectAll(bookmarks: BookmarkStore) async {
        guard let queue = Database.shared.dbQueue else { return }
        cancelled = false
        isRunning = true
        finished = false

        var addedImageURLs: [URL] = []

        for i in folders.indices {
            if cancelled { break }
            guard let location = folders[i].newLocation else { continue }
            folders[i].status = .working

            _ = bookmarks.addRoot(at: location)

            // Enumerate + hash the folder's files off the main actor.
            let rootID = folders[i].id
            let occurrences = archive.roots.first { $0.path == rootID } != nil
                ? archive.files.flatMap { $0.occurrences }.filter { $0.root_path == rootID }
                : []
            let result = await Task.detached(priority: .utility) { () -> (disk: [DiskFile], urls: [URL]) in
                var disk: [DiskFile] = []
                var urls: [URL] = []
                let fm = FileManager.default
                guard let en = fm.enumerator(at: location, includingPropertiesForKeys: nil) else {
                    return ([], [])
                }
                for case let url as URL in en {
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                    else { continue }
                    let hash = HashService.sha256(of: url)
                    disk.append(DiskFile(path: url.standardizedFileURL.path,
                                         basename: url.lastPathComponent, contentHash: hash))
                    urls.append(url)
                }
                return (disk, urls)
            }.value

            addedImageURLs.append(contentsOf: result.urls)

            let expected = Dictionary(uniqueKeysWithValues:
                occurrences.compactMap { o -> (String, String)? in
                    guard let h = hashForOriginalPath[o.original_path] else { return nil }
                    return (o.original_path, h)
                })
            let match = ReconnectMatcher.match(occurrences: occurrences, disk: result.disk,
                                               expectedHash: expected)

            // Apply metadata per backup file.
            var byFile: [String: [OccurrenceMatch]] = [:]
            for m in match.matches {
                guard let h = hashForOriginalPath[m.occurrence.original_path] else { continue }
                byFile[h, default: []].append(m)
            }
            for (hash, matches) in byFile {
                guard let file = hashToFile[hash] else { continue }
                try? await ReconnectApplier.applyMeta(matches: matches, file: file, queue: queue)
            }

            folders[i].status = match.unmatched.isEmpty ? .clean
                : .flagged(unmatched: match.unmatched.count)
        }

        // Collections + stars from the now-populated DB.
        if let map = try? await ReconnectApplier.currentFileIDForHash(queue: queue) {
            try? await ReconnectApplier.applyCollections(archive, fileIDForHash: map, queue: queue)
            try? await ReconnectApplier.applyStars(archive, queue: queue)
            for i in collectionStatuses.indices {
                let coll = archive.collections.first { $0.id == collectionStatuses[i].id }
                collectionStatuses[i].reconnected = coll?.members
                    .filter { map[$0.content_hash] != nil }.count ?? 0
            }
        }

        // Reconcile: analyze anything new/changed the backup didn't cover.
        if !addedImageURLs.isEmpty {
            await AnalyzePipeline.shared.analyzePending(in: addedImageURLs)
        }

        isRunning = false
        finished = true
    }
}
```

- [ ] **Step 2: Verify `HashService.sha256(of:)` signature**

Run: `grep -n "func sha256" Muse/Muse/Indexing/HashService.swift`
Expected: a `static func sha256(of url: URL) -> String?` (or similar). If the name/shape differs, adjust the call in `reconnectAll` accordingly (it returns an optional hash; `DiskFile.contentHash` is `String?`).

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Backup/ReconnectModel.swift
git commit -m "feat: reconnect model orchestrates index + match + apply"
```

---

## Task 8: Restore picker + AppState wiring + ContentView sheet

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift` (replace `beginRestorePicker` stub; add `@Published var reconnectModel` + `reconnectShown`)
- Modify: `Muse/Muse/ContentView.swift` (`.sheet` presenting the wizard)

**Interfaces:**
- Consumes: `BackupDocument.decode` (Task 1), `ReconnectModel` (Task 7).
- Produces: `AppState.reconnectModel: ReconnectModel?`, `AppState.reconnectShown: Bool`, `AppState.beginRestorePicker()`.

- [ ] **Step 1: Add state + picker to AppState**

Replace the temporary `func beginRestorePicker() {}` stub with:

```swift
    @Published var reconnectModel: ReconnectModel?
    @Published var reconnectShown = false

    /// Pick a .muselibrary file and open the Reconnect wizard.
    func beginRestorePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedFileTypes = [BackupDocument.fileExtension]
        panel.message = "Choose the Muse backup file you exported on your other Mac."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let archive = try BackupDocument.decode(data)
            reconnectModel = ReconnectModel(archive: archive)
            reconnectShown = true
        } catch {
            print("[Backup] restore load failed: \(error)")
        }
    }
```

(Place the two `@Published` lines with the other published modal flags near `settingsShown`.)

- [ ] **Step 2: Present the wizard sheet in ContentView**

Beside the other `.sheet` modifiers (near `settingsShown`'s sheet), add:

```swift
        .sheet(isPresented: $appState.reconnectShown) {
            if let model = appState.reconnectModel {
                ReconnectWizard(model: model, isPresented: $appState.reconnectShown,
                                bookmarks: appState.bookmarks)
            }
        }
```

(Confirm `appState.bookmarks` is accessible — it's the `BookmarkStore` AppState already owns; if it's private, expose it `let bookmarks` or add a passthrough. `ReconnectWizard` is created in Task 9.)

- [ ] **Step 3: Temporarily stub the view so this task builds**

Create `Muse/Muse/Views/Backup/ReconnectWizard.swift` with a minimal stub (Task 9 fills it in):

```swift
import SwiftUI

struct ReconnectWizard: View {
    @ObservedObject var model: ReconnectModel
    @Binding var isPresented: Bool
    let bookmarks: BookmarkStore
    var body: some View { Text("Reconnect").frame(width: 600, height: 720) }
}
```

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Models/AppState.swift Muse/Muse/ContentView.swift Muse/Muse/Views/Backup/ReconnectWizard.swift
git commit -m "feat: restore file picker + wizard sheet wiring"
```

---

## Task 9: The Reconnect wizard UI

**Files:**
- Modify: `Muse/Muse/Views/Backup/ReconnectWizard.swift` (replace the stub)

**Interfaces:**
- Consumes: `ReconnectModel` (Task 7), `BookmarkStore`.

Requirements (from spec, Global Constraints):
- `.frame(width: 600, height: 720)`, `.padding(28)`. Title "Restore from Backup" at `.system(size: 24, weight: .semibold)`. Section heads 15pt semibold, body 13pt secondary. Vertical `ScrollView(showsIndicators: false)`.
- **No `SheetCloseButton`.** A single **Cancel** button (bottom). While `model.isRunning`, Cancel shows a confirm; while idle/finished, Cancel closes.
- Top: a "Choose where your files are" row with a **"Point at folder…"** button → `NSOpenPanel` (directories) → `model.autoMap(parent:)`.
- Folder list: each `FolderRow` shows name, its mapped location (or "Not located"), a per-row **Locate…** button (`NSOpenPanel` dir → `model.setLocation`), and a status glyph: pending (—), working (ProgressView), clean (green checkmark), flagged (orange triangle + "N not found").
- A **"Reconnect All"** button (disabled if no folder has a location, or while running) → `Task { await model.reconnectAll(bookmarks: bookmarks) }`.
- Collections readout: "`\(reconnectedCount)` / `\(total)` collections re-established" + `model.overallPercent`%, then per-collection rows showing `reconnected/total` with the names of collections still at 0 subtly flagged.
- When `model.finished`, the primary button becomes **Done** (closes).

- [ ] **Step 1: Write the wizard**

```swift
//  ReconnectWizard.swift
//  Muse
//
//  Locked restore sheet: map each backed-up folder to its new location, then
//  Reconnect All. Matches InfoSheet chrome (600x720). No X — Cancel/Done only.
//

import SwiftUI
import AppKit

struct ReconnectWizard: View {
    @ObservedObject var model: ReconnectModel
    @Binding var isPresented: Bool
    let bookmarks: BookmarkStore

    @State private var confirmCancel = false

    private var anyLocated: Bool { model.folders.contains { $0.newLocation != nil } }
    private var collectionsDone: Int { model.collectionStatuses.filter { $0.reconnected > 0 }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Restore from Backup")
                .font(.system(size: 24, weight: .semibold))
                .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    pointAtParent
                    folderSection
                    collectionSection
                }
            }

            Spacer(minLength: 16)
            footer
        }
        .padding(28)
        .frame(width: 600, height: 720)
        .alert("Stop reconnecting?", isPresented: $confirmCancel) {
            Button("Keep Going", role: .cancel) {}
            Button("Stop", role: .destructive) { model.cancel(); isPresented = false }
        } message: {
            Text("Reconnection is in progress. Stopping leaves it partially done; you can restore again later.")
        }
    }

    private var pointAtParent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where are your files?").font(.system(size: 15, weight: .semibold))
            Text("Point at the folder that holds your copied library and Muse will line up your folders automatically. You can also locate any folder by hand below.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Button("Point at folder…") {
                if let url = pickDirectory() { model.autoMap(parent: url) }
            }
            .disabled(model.isRunning)
        }
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Folders").font(.system(size: 15, weight: .semibold))
            ForEach(model.folders) { folder in
                HStack(spacing: 10) {
                    statusGlyph(folder.status)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.displayName).font(.system(size: 13, weight: .medium))
                        Text(folder.newLocation?.path ?? "Not located")
                            .font(.system(size: 11))
                            .foregroundStyle(folder.newLocation == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Locate…") {
                        if let url = pickDirectory() { model.setLocation(url, forFolder: folder.id) }
                    }
                    .disabled(model.isRunning)
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
    }

    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Collections").font(.system(size: 15, weight: .semibold))
            Text("\(collectionsDone) / \(model.collectionStatuses.count) re-established · \(model.overallPercent)% of images reconnected")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ForEach(model.collectionStatuses) { c in
                HStack {
                    Text(c.name).font(.system(size: 12))
                        .foregroundStyle(c.reconnected == 0 ? .secondary : .primary)
                    Spacer()
                    Text("\(c.reconnected)/\(c.total)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(c.reconnected == 0 ? .orange : .secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(model.isRunning ? "Cancel" : "Cancel") {
                if model.isRunning { confirmCancel = true } else { isPresented = false }
            }
            Spacer()
            if model.finished {
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Reconnect All") {
                    Task { await model.reconnectAll(bookmarks: bookmarks) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!anyLocated || model.isRunning)
            }
        }
    }

    @ViewBuilder
    private func statusGlyph(_ status: ReconnectModel.FolderStatus) -> some View {
        switch status {
        case .pending: Image(systemName: "minus").foregroundStyle(.secondary)
        case .working: ProgressView().controlSize(.small)
        case .clean: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .flagged(let n):
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(n) not found").font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
    }

    private func pickDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual round-trip test**

1. On a library with a few folders + a collection, **Back Up Muse…**.
2. Wipe the DB: quit, delete `~/Library/Containers/com.tarrats.Muse/Data/Library/Application Support/Muse/muse.sqlite`, relaunch (blank library).
3. Move/rename one image inside a test folder to exercise both match paths.
4. **Restore from Backup…** → pick the file → **Point at folder…** at the parent → confirm folders auto-map → **Reconnect All**.
5. Verify: folders show ✓ (or ⚑ for the file you renamed if its bytes changed), the collections readout climbs, and after **Done** the collections appear in the sidebar/Collections page with their images and tags. Confirm no empty/ghost collections and no broken tiles.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Views/Backup/ReconnectWizard.swift
git commit -m "feat: Reconnect wizard UI (InfoSheet-sized, Cancel-only)"
```

---

## Task 10: Info modal "Back Up & Restore" section

**Files:**
- Modify: `Muse/Muse/Views/InfoSheet.swift`

- [ ] **Step 1: Add the section**

In `InfoSheet.body`, add a new `section(...)` + `rowDivider` (place it right after the "iCloud sync" section, before "Grid & appearance"):

```swift
                    rowDivider
                    section("Back Up & Restore", """
                        Muse keeps your collections, tags, and folder list on \
                        this Mac — not inside your files. Before moving to a new \
                        Mac, choose Muse ▸ Back Up Muse… to save one backup file; \
                        keep it somewhere safe and carry it over with your files. \
                        On the new Mac, choose Muse ▸ Restore from Backup…, point \
                        Muse at your folders, and it reconnects everything by \
                        matching each file's contents — even if you renamed or \
                        rearranged them. Collections with no files on the new Mac \
                        simply don't appear; nothing is ever left broken.
                        """)
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual check**

Open the ⓘ About modal; confirm the new "Back Up & Restore" section reads well and matches the surrounding type.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Views/InfoSheet.swift
git commit -m "docs: explain Back Up & Restore in the About modal"
```

---

## Task 11: Full suite green + final verification

**Files:** none (verification only).

- [ ] **Step 1: Run the whole unit suite**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **` with the 5 new test files included; no regressions.

- [ ] **Step 2: Confirm no network / no destructive APIs were introduced**

Run: `grep -rn "URLSession\|\.recycle\|unlink\|removeItem\|moveItem" Muse/Muse/Backup`
Expected: no matches (the backup layer touches the DB + reads files for hashing only).

- [ ] **Step 3: Commit any final fixups (if needed)**

```bash
git add -A && git commit -m "test: backup & reconnect suite green"
```

---

## Self-Review

**Spec coverage:**
- Explicit export file (one `.muselibrary`) → Tasks 1, 6. ✅
- Content fingerprint + filename fallback → Task 3. ✅
- Option-1 contents (folders, collections, tags manual+AI, stars, AI metadata; excludes thumbnails/OCR) → Tasks 2, 5. ✅
- UUID↔content-hash re-keying (membership/cover/exclusions) → Tasks 2, 4, 5. ✅
- Tags re-applied at new parent_dir, manual-beats-vision → Task 5. ✅
- Locked wizard, folder rows, point-at-parent auto-map + Locate, Reconnect All batch, per-folder clean/flagged, collections readout + overall % → Tasks 7, 9. ✅
- No dead collections (auto-empty dropped, manual-empty kept, partial shows survivors) → Task 4. ✅
- Reconcile new/changed via existing pipeline → Task 7 (`analyzePending`). ✅
- Reconnect into a non-blank Mac (periodic backup) → Tasks 5 (ON CONFLICT upserts) + 7. ✅
- Wizard matches InfoSheet size/type, no ✕, Cancel only → Task 9. ✅
- Info modal section → Task 10. ✅

**Placeholder scan:** Task 6 deliberately introduces a one-line `beginRestorePicker()` stub, explicitly replaced in Task 8; Task 8 introduces a `ReconnectWizard` stub explicitly replaced in Task 9. No other placeholders.

**Type consistency:** `BackupArchive`/`BackupFile`/`BackupOccurrence`/`BackupCollection`/`BackupMember` shared across Tasks 1–7; `DiskFile`/`OccurrenceMatch`/`MatchResult` from Task 3 used in Task 7; `MaterializedCollection`/`MaterializedMember` from Task 4 used in Task 5; `ReconnectModel.FolderStatus`/`FolderRow`/`CollectionStatusRow` from Task 7 used in Task 9. Names checked consistent.
