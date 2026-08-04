# Per-File Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a file on disk — not its bytes — the unit of identity, so twelve byte-identical copies carry twelve independent sets of edits, tags, notes and collection memberships.

**Architecture:** Drop `files.content_hash UNIQUE` so each alive path owns its own `files` row. `content_hash` survives as a *grouping* key (Find Duplicates, analysis reuse). Because `file_id` then means "this file", the tables already keyed on `file_id` alone — collections, exclusions, FTS — become correct with no schema change, and `parent_dir` becomes a redundant second key column that is deleted. The indexer's three row-sharing branches collapse into one "new file, inherit from donor" path.

**Tech Stack:** Swift 6 / SwiftUI, GRDB (SQLite, `DatabaseMigrator`), XCTest (`MuseTests`), macOS 14.6+.

**Spec:** `docs/superpowers/specs/2026-08-03-per-file-identity-design.md`

## Global Constraints

- **Migrations are append-only.** Chain currently runs to `v23_edit_luts`; this plan adds **v24** and **v25**. Never edit a registered migration.
- **GRDB writes are async** (`try await queue.write { }`); rows insert as `var`.
- **Files are never deleted, only moved to Trash** — no `unlink` anywhere.
- **The app is localized.** Any new user-facing string must be added to `Localizable.xcstrings` with a French value. This plan is expected to add **none**.
- **Release build must stay warning-free.**
- **`./scripts/audit-invariants.sh` must be green before every commit** (15 checks; task 7 adds a 16th).
- **Test tier rule:** while iterating use `-only-testing:MuseTests/<TheOneClass>`. Run the whole unit target **once**, at task 7. Do not run `MuseUITests`.
- **Structural invariant introduced by this plan:** *a `files` row has at most one alive path.* SQLite cannot enforce it; tests must.

---

### Task 1: Migration v24 — split shared file rows

This alone fixes the reported bug for data that already exists.

**Files:**
- Modify: `Muse/Muse/Database/Database.swift` (append migration after `v23_edit_luts`, ~line 580)
- Create: `Muse/MuseTests/PerFileIdentityMigrationTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: post-v24 database where every alive `paths` row has its own `files` row. Later tasks rely on the invariant `COUNT(alive paths per file_id) <= 1`.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/PerFileIdentityMigrationTests.swift`. Model it on the existing migration tests (`grep -l "makeMigrator" Muse/MuseTests` for the setup idiom — build an in-memory `DatabaseQueue`, run the migrator up to `v23_edit_luts`, seed rows, then migrate to the latest).

```swift
import XCTest
import GRDB
@testable import Muse

final class PerFileIdentityMigrationTests: XCTestCase {

    /// Seeds one files row shared by `paths`, migrated only as far as v23.
    private func seededQueue(paths: [String],
                             hash: String = "abc123") throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        var migrator = Database.makeMigrator()
        try migrator.migrate(queue, upTo: "v23_edit_luts")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash)
                VALUES ('F', ?, 'image', 0, ?)
                """, arguments: [hash, hash])
            for (i, p) in paths.enumerated() {
                try db.execute(sql: """
                    INSERT INTO paths (id, file_id, absolute_path, is_alive)
                    VALUES (?, 'F', ?, 1)
                    """, arguments: ["P\(i)", p])
            }
            try db.execute(sql: """
                INSERT INTO files_fts (file_id, basename, ocr_text, caption)
                VALUES ('F', ?, '', '')
                """, arguments: [(paths[0] as NSString).lastPathComponent])
        }
        return queue
    }

    private func migrate(_ queue: DatabaseQueue) throws {
        try Database.makeMigrator().migrate(queue)
    }

    /// THE REPORTED BUG: 12 copies in ONE folder must end up as 12 rows.
    func testSameFolderCopiesSplitIntoOneRowEach() throws {
        let dir = "/Lib/Raw Files"
        let paths = (0..<12).map { "\(dir)/copy\($0).ARW" }
        let queue = try seededQueue(paths: paths)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
                VALUES ('F', ?, '{"v":1}', 'h1', 1, 99)
                """, arguments: [dir])
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source, confidence, model_version)
                VALUES ('T1', 'F', ?, 'autumn', 'manual', 1.0, 'v1')
                """, arguments: [dir])
            try db.execute(sql: """
                INSERT INTO notes (file_id, parent_dir, body, updated_at)
                VALUES ('F', ?, 'my note', 5)
                """, arguments: [dir])
        }

        try migrate(queue)

        try queue.read { db in
            // One files row per alive path.
            let fileIDs = try String.fetchAll(db, sql:
                "SELECT DISTINCT file_id FROM paths WHERE is_alive = 1")
            XCTAssertEqual(fileIDs.count, 12)
            // Each inherits a COPY of the shared edit, tag and note.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edits"), 12)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags"), 12)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes"), 12)
            // Every copy findable by its OWN name.
            for p in paths {
                let base = (p as NSString).lastPathComponent
                let n = try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM files_fts WHERE basename = ?", arguments: [base])
                XCTAssertEqual(n, 1, "\(base) not searchable")
            }
        }
    }

    /// The invariant that replaces content_hash UNIQUE.
    func testNoFileRowKeepsTwoAlivePaths() throws {
        let queue = try seededQueue(paths: ["/A/x.jpg", "/A/y.jpg", "/B/x.jpg"])
        try migrate(queue)
        try queue.read { db in
            let worst = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(n), 0) FROM
                  (SELECT COUNT(*) AS n FROM paths WHERE is_alive = 1 GROUP BY file_id)
                """)
            XCTAssertEqual(worst, 1)
        }
    }

    /// Per-FOLDER user data must land on the row for that folder, not be smeared.
    func testCrossFolderDataLandsOnItsOwnFolderRow() throws {
        let queue = try seededQueue(paths: ["/A/x.jpg", "/B/x.jpg"])
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO notes (file_id, parent_dir, body, updated_at)
                VALUES ('F', '/A', 'note A', 1), ('F', '/B', 'note B', 2)
                """)
        }
        try migrate(queue)
        try queue.read { db in
            let noteFor: (String) throws -> String? = { path in
                try String.fetchOne(db, sql: """
                    SELECT n.body FROM notes n
                    JOIN paths p ON p.file_id = n.file_id AND p.is_alive = 1
                    WHERE p.absolute_path = ?
                    """, arguments: [path])
            }
            XCTAssertEqual(try noteFor("/A/x.jpg"), "note A")
            XCTAssertEqual(try noteFor("/B/x.jpg"), "note B")
        }
    }

    /// Content-derived analysis is COPIED, so no copy is left looking unanalyzed.
    func testDerivedAnalysisIsCopiedToEveryRow() throws {
        let queue = try seededQueue(paths: ["/A/x.jpg", "/A/y.jpg"])
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, capture_date, camera_make)
                VALUES ('F', 1700000000, 'Sony')
                """)
            try db.execute(sql: """
                INSERT INTO embeddings (file_id, vector, model_version, updated_at)
                VALUES ('F', x'00', 'm1', 1)
                """)
        }
        try migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photo_meta"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings"), 2)
            let unanalyzed = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM files WHERE analyzed_hash IS NULL OR analyzed_hash <> content_hash")
            XCTAssertEqual(unanalyzed, 0)
        }
    }

    /// Manual collection membership survives on every copy.
    func testCollectionMembershipCopiedToEveryRow() throws {
        let queue = try seededQueue(paths: ["/A/x.jpg", "/A/y.jpg"])
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO collections (id, name, sort_order, model_version, is_hidden)
                VALUES ('C', 'Faves', 0, 'v1', 0)
                """)
            try db.execute(sql: """
                INSERT INTO collection_members (collection_id, file_id, added_by)
                VALUES ('C', 'F', 'manual')
                """)
        }
        try migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_members"), 2)
        }
    }

    /// Dead paths stay attached to the surviving original row.
    func testDeadPathsStayOnTheKeptRow() throws {
        let queue = try seededQueue(paths: ["/A/x.jpg", "/A/y.jpg"])
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('PD', 'F', '/A/gone.jpg', 0)
                """)
        }
        try migrate(queue)
        try queue.read { db in
            let owner = try String.fetchOne(db, sql:
                "SELECT file_id FROM paths WHERE id = 'PD'")
            XCTAssertEqual(owner, "F")
        }
    }

    /// A single-path file must be left completely alone.
    func testSolePathFileIsUntouched() throws {
        let queue = try seededQueue(paths: ["/A/only.jpg"])
        try migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT id FROM files"), "F")
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test \
  -only-testing:MuseTests/PerFileIdentityMigrationTests 2>&1 | tail -20
```

Expected: FAIL — `testSameFolderCopiesSplitIntoOneRowEach` finds 1 distinct `file_id`, not 12.

- [ ] **Step 3: Write the migration**

In `Database.swift`, immediately after the `v23_edit_luts` block:

```swift
migrator.registerMigration("v24_per_file_identity") { db in
    // Identity becomes the FILE ON DISK, not its bytes. content_hash was
    // UNIQUE, so N byte-identical files collapsed to one row and shared one
    // edit stack, one tag set, one note and one set of collection
    // memberships — editing one copy changed all of them (the reported bug:
    // 12 .ARW copies in one folder, 12 alive paths, 1 edits row).
    //
    // Each alive path gets its own files row here. content-DERIVED data
    // (EXIF, traits, place, embeddings, palette/caption/dims) is COPIED,
    // because it is identical for identical bytes and expensive to recompute
    // — no copy must come out of this migration looking unanalyzed.
    // User-authored data is copied too: the owner's rule is that a copy
    // INHERITS, so nothing visible today is lost and the copies diverge from
    // the next edit forward.
    //
    // The lowest absolute_path keeps the original row, so the choice is
    // deterministic and re-runnable in tests.

    // content_hash UNIQUE is what forced the collapse. Rebuild the index
    // non-unique; it stays the grouping key for Find Duplicates and for
    // analysis reuse.
    try db.execute(sql: "DROP INDEX IF EXISTS sqlite_autoindex_files_1")
    // SQLite cannot drop an implicit UNIQUE — rebuild the table instead.
    try db.execute(sql: "ALTER TABLE files RENAME TO files_old")
    try db.execute(sql: """
        CREATE TABLE files (
            id TEXT PRIMARY KEY NOT NULL,
            content_hash TEXT,
            kind TEXT NOT NULL,
            size_bytes INTEGER,
            width INTEGER,
            height INTEGER,
            duration_seconds REAL,
            created_at INTEGER,
            modified_at INTEGER,
            last_seen_at INTEGER NOT NULL,
            caption TEXT,
            dominant_color TEXT,
            feature_print BLOB,
            palette TEXT,
            analyzed_hash TEXT,
            intent TEXT,
            intent_model_version TEXT,
            lat REAL,
            lon REAL,
            coords_scanned_hash TEXT,
            last_viewed_at INTEGER
        )
        """)
    try db.execute(sql: "INSERT INTO files SELECT * FROM files_old")
    try db.execute(sql: "DROP TABLE files_old")
    try db.execute(sql: "CREATE INDEX files_content_hash_idx ON files(content_hash)")

    // Every alive path beyond the first, per file, lowest path keeps the row.
    let rows = try Row.fetchAll(db, sql: """
        SELECT p.id AS path_id, p.file_id AS file_id, p.absolute_path AS path
        FROM paths p
        WHERE p.is_alive = 1
          AND p.file_id IN (SELECT file_id FROM paths WHERE is_alive = 1
                            GROUP BY file_id HAVING COUNT(*) > 1)
        ORDER BY p.file_id, p.absolute_path
        """)

    var seen: Set<String> = []
    for row in rows {
        guard let pathID: String = row["path_id"],
              let oldID: String = row["file_id"],
              let absPath: String = row["path"] else { continue }
        // First (lowest) path per file keeps the original row.
        if seen.insert(oldID).inserted { continue }

        let newID = UUID().uuidString
        let dir = (absPath as NSString).deletingLastPathComponent
        let base = (absPath as NSString).lastPathComponent

        // 1. The files row itself, every column but the id.
        try db.execute(sql: """
            INSERT INTO files
            SELECT ?, content_hash, kind, size_bytes, width, height,
                   duration_seconds, created_at, modified_at, last_seen_at,
                   caption, dominant_color, feature_print, palette,
                   analyzed_hash, intent, intent_model_version, lat, lon,
                   coords_scanned_hash, last_viewed_at
            FROM files WHERE id = ?
            """, arguments: [newID, oldID])

        // 2. Content-derived rows — copied so the new row is not "unanalyzed".
        try db.execute(sql: """
            INSERT INTO photo_meta SELECT ?, exif_scanned_hash, capture_date,
                capture_md, camera_make, camera_model, lens, iso, f_number,
                exposure_seconds, focal_length, focal_length_35mm, flash_fired
            FROM photo_meta WHERE file_id = ?
            """, arguments: [newID, oldID])
        try db.execute(sql: """
            INSERT INTO photo_traits SELECT ?, traits_scanned_hash, traits_version,
                face_count, largest_face_frac, face_quality, pet_count, sharpness,
                clip_high_r, clip_high_g, clip_high_b, clip_low, noise_sigma
            FROM photo_traits WHERE file_id = ?
            """, arguments: [newID, oldID])
        try db.execute(sql: """
            INSERT INTO places SELECT ?, geocoded_hash, dataset_version,
                city, admin, country, place_key
            FROM places WHERE file_id = ?
            """, arguments: [newID, oldID])
        try db.execute(sql: """
            INSERT INTO embeddings SELECT ?, vector, model_version, updated_at
            FROM embeddings WHERE file_id = ?
            """, arguments: [newID, oldID])
        try db.execute(sql: """
            INSERT INTO clip_embeddings SELECT ?, embedded_hash, model_generation, vector
            FROM clip_embeddings WHERE file_id = ?
            """, arguments: [newID, oldID])

        // 3. FTS carries THIS path's own basename — which is how the other
        //    eleven filenames become searchable for the first time.
        try db.execute(sql: """
            INSERT INTO files_fts (file_id, basename, ocr_text, caption)
            SELECT ?, ?, ocr_text, caption FROM files_fts WHERE file_id = ?
            """, arguments: [newID, base, oldID])

        // 4. User-authored data for THIS path's folder, copied (inherit rule).
        //    Same-folder copies therefore each get their own copy of what they
        //    were sharing; cross-folder copies take only their own folder's.
        try db.execute(sql: """
            INSERT INTO tags (id, file_id, parent_dir, label, source, confidence, model_version)
            SELECT lower(hex(randomblob(16))), ?, parent_dir, label, source,
                   confidence, model_version
            FROM tags WHERE file_id = ? AND parent_dir = ?
            """, arguments: [newID, oldID, dir])
        try db.execute(sql: """
            INSERT INTO notes (file_id, parent_dir, body, updated_at)
            SELECT ?, parent_dir, body, updated_at
            FROM notes WHERE file_id = ? AND parent_dir = ?
            """, arguments: [newID, oldID, dir])
        try db.execute(sql: """
            INSERT INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
            SELECT ?, parent_dir, stack, stack_hash, process_version, updated_at
            FROM edits WHERE file_id = ? AND parent_dir = ?
            """, arguments: [newID, oldID, dir])
        try db.execute(sql: """
            INSERT INTO edit_versions (id, file_id, parent_dir, kind, name, stack, created_at)
            SELECT lower(hex(randomblob(16))), ?, parent_dir, kind, name, stack, created_at
            FROM edit_versions WHERE file_id = ? AND parent_dir = ?
            """, arguments: [newID, oldID, dir])

        // 5. Collections: every copy is a member today, so keep it one.
        try db.execute(sql: """
            INSERT OR IGNORE INTO collection_members (collection_id, file_id, added_by)
            SELECT collection_id, ?, added_by FROM collection_members WHERE file_id = ?
            """, arguments: [newID, oldID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO collection_exclusions (collection_id, file_id)
            SELECT collection_id, ? FROM collection_exclusions WHERE file_id = ?
            """, arguments: [newID, oldID])

        // 6. Re-point the path. Dead paths stay on the original row.
        try db.execute(sql: "UPDATE paths SET file_id = ? WHERE id = ?",
                       arguments: [newID, pathID])
    }

    // Derived caches — the next Find Duplicates run rebuilds them.
    try db.execute(sql: "DELETE FROM duplicate_members")
    try db.execute(sql: "DELETE FROM duplicate_groups")
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test \
  -only-testing:MuseTests/PerFileIdentityMigrationTests 2>&1 | tail -20
```

Expected: all 7 tests PASS.

- [ ] **Step 5: Verify the existing migration suite still passes**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test \
  -only-testing:MuseTests/DatabaseMigrationTests 2>&1 | tail -20
```

If that class name does not exist, find it with `grep -rl "makeMigrator" Muse/MuseTests` and run that class instead. The `files` table rebuild is the risk here — a column typo surfaces as a decode failure in `FileRow`.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Database/Database.swift Muse/MuseTests/PerFileIdentityMigrationTests.swift
git commit -m "v24: one files row per file on disk"
```

---

### Task 2: Indexer — a new copy is a new file that inherits

Task 1 fixed existing data. Without this task, the next duplicate re-shares a row and the bug returns.

**Files:**
- Modify: `Muse/Muse/Indexing/Indexer.swift:129-419` (`reconcile`)
- Create: `Muse/Muse/Indexing/InheritDonor.swift`
- Test: `Muse/MuseTests/InheritDonorTests.swift`, `Muse/MuseTests/IndexerReconcileTests.swift` (existing — expectations change)

**Interfaces:**
- Consumes: the v24 invariant (≤1 alive path per files row).
- Produces:
  - `InheritDonor.pick(candidates:targetDir:) -> String?` — pure, returns the donor `file_id`.
  - `Indexer.inherit(db:from:to:targetDir:)` — copies derived + user data onto a new row.

- [ ] **Step 1: Write the failing donor test**

Create `Muse/MuseTests/InheritDonorTests.swift`:

```swift
import XCTest
@testable import Muse

final class InheritDonorTests: XCTestCase {

    private func c(_ id: String, _ dir: String, edited: Int64?) -> InheritDonor.Candidate {
        InheritDonor.Candidate(fileID: id, parentDir: dir, absolutePath: "\(dir)/\(id).jpg",
                               editUpdatedAt: edited)
    }

    func testPrefersACopyInTheSameFolder() {
        let picked = InheritDonor.pick(
            candidates: [c("a", "/Other", edited: 999), c("b", "/Here", edited: 1)],
            targetDir: "/Here")
        XCTAssertEqual(picked, "b")
    }

    func testFallsBackToMostRecentlyEdited() {
        let picked = InheritDonor.pick(
            candidates: [c("a", "/X", edited: 5), c("b", "/Y", edited: 50)],
            targetDir: "/Here")
        XCTAssertEqual(picked, "b")
    }

    func testSameFolderBeatsMoreRecentEditElsewhere() {
        let picked = InheritDonor.pick(
            candidates: [c("a", "/Here", edited: nil), c("b", "/Y", edited: 50)],
            targetDir: "/Here")
        XCTAssertEqual(picked, "a")
    }

    func testTieBreaksOnLowestPathSoItIsDeterministic() {
        let picked = InheritDonor.pick(
            candidates: [c("zzz", "/Here", edited: nil), c("aaa", "/Here", edited: nil)],
            targetDir: "/Here")
        XCTAssertEqual(picked, "aaa")
    }

    func testNoCandidatesIsNil() {
        XCTAssertNil(InheritDonor.pick(candidates: [], targetDir: "/Here"))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test \
  -only-testing:MuseTests/InheritDonorTests 2>&1 | tail -20
```

Expected: FAIL — `Cannot find 'InheritDonor' in scope`.

- [ ] **Step 3: Write `InheritDonor`**

Create `Muse/Muse/Indexing/InheritDonor.swift`:

```swift
//
//  InheritDonor.swift
//  Muse
//
//  Which existing copy a NEW copy inherits from.
//
//  Owner decision (2026-08-03): duplicating a photo that already carries
//  edits should start from those edits and diverge, not from blank — "there
//  will be some cases of a user wanting to try two different edits to
//  duplicate images to see the differences".
//
//  Pure so the rule is testable without a database. The ordering is total:
//  same folder, then most recently edited, then lowest path — so the same
//  candidate set always yields the same donor regardless of query order.
//

import Foundation

nonisolated enum InheritDonor {
    struct Candidate: Equatable, Sendable {
        var fileID: String
        var parentDir: String
        var absolutePath: String
        /// `edits.updated_at`, or nil when this copy carries no edit.
        var editUpdatedAt: Int64?
    }

    static func pick(candidates: [Candidate], targetDir: String) -> String? {
        candidates.min { lhs, rhs in
            let lSame = lhs.parentDir == targetDir
            let rSame = rhs.parentDir == targetDir
            if lSame != rSame { return lSame }
            let lEdit = lhs.editUpdatedAt ?? .min
            let rEdit = rhs.editUpdatedAt ?? .min
            if lEdit != rEdit { return lEdit > rEdit }
            return lhs.absolutePath < rhs.absolutePath
        }?.fileID
    }
}
```

- [ ] **Step 4: Run the donor tests to verify they pass**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test \
  -only-testing:MuseTests/InheritDonorTests 2>&1 | tail -20
```

Expected: 5 PASS.

- [ ] **Step 5: Write the failing reconcile isolation test**

Append to `Muse/MuseTests/IndexerReconcileTests.swift` (follow the file's existing in-memory-queue setup):

```swift
/// THE REPORTED BUG, at the indexer level: a second copy of the same bytes
/// in the same folder must become its own row, and editing one must not
/// touch the other.
func testSameFolderCopyBecomesItsOwnRow() throws {
    // Index /A/one.jpg, then /A/two.jpg with identical bytes.
    // Assert: two files rows, two alive paths, one alive path each.
}

/// The inherit rule end to end.
func testNewCopyInheritsTheDonorsEditAndTags() throws {
    // Give /A/one.jpg an edit stack + a manual tag, then index /A/two.jpg.
    // Assert: two.jpg's own edits row exists with the same stack, and its
    // own tag row exists — and editing two.jpg leaves one.jpg's stack alone.
}

/// Inheriting must not re-run Vision.
func testNewCopyIsNotMarkedUnanalyzed() throws {
    // Assert the new row's analyzed_hash == content_hash.
}
```

Fill each body out following the existing tests in that file for the `reconcile` call shape.

- [ ] **Step 6: Run it to verify it fails**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test \
  -only-testing:MuseTests/IndexerReconcileTests 2>&1 | tail -30
```

Expected: the three new tests FAIL (one row, shared edit).

- [ ] **Step 7: Rewrite the three sharing branches in `reconcile`**

Three edits in `Indexer.swift`:

1. **`Indexer.swift:180-250` — the hash-collision branch.** Delete it. Two rows may now legally share a `content_hash`, so when a file's bytes change to match another file's, nothing needs re-linking: fall through to the plain edit-in-place update.

2. **`Indexer.swift:251-341` — the split branch.** Delete the `aliveCount > 1` split entirely and keep only the `else` body (update `content_hash`, `size_bytes`, `modified_at`, `last_seen_at`, `analyzed_hash = nil`). By the v24 invariant `aliveCount` is always 1.

3. **`Indexer.swift:368-400` — "brand-new path pointing at known content".** This is where sharing was created. Replace with: make a NEW `files` row, then inherit.

```swift
// A new path whose bytes match an existing file is a COPY, not another
// name for the same photo. It gets its own row — that is the whole point
// of per-file identity — and inherits the donor's edits, tags, note and
// collection memberships, then diverges (see InheritDonor).
var newFile = makeFile(hash: hash, kind: kind, size: sizeBytes,
                       created: createdAt, modified: modifiedAt, now: now)
try newFile.insert(db)
var newPath = PathRow(id: UUID().uuidString, file_id: newFile.id,
                      absolute_path: absPath, bookmark_data: nil, is_alive: 1)
try newPath.insert(db)
try insertBasenameFTS(db: db, fileID: newFile.id, absPath: absPath)
let dir = TagScope.parentDir(ofPath: absPath)
if let donor = try pickDonor(db: db, hash: hash, excluding: newFile.id, targetDir: dir) {
    try inherit(db: db, from: donor, to: newFile.id, targetDir: dir)
}
return false
```

Add both helpers to `Indexer`:

```swift
/// Existing rows with these bytes, as inheritance candidates.
static func pickDonor(db: GRDB.Database, hash: String,
                      excluding newID: String, targetDir: String) throws -> String? {
    let rows = try Row.fetchAll(db, sql: """
        SELECT f.id AS fid, p.absolute_path AS path, e.updated_at AS edited
        FROM files f
        JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
        LEFT JOIN edits e ON e.file_id = f.id
        WHERE f.content_hash = ? AND f.id <> ?
        """, arguments: [hash, newID])
    let candidates = rows.compactMap { row -> InheritDonor.Candidate? in
        guard let fid: String = row["fid"], let path: String = row["path"] else { return nil }
        return InheritDonor.Candidate(
            fileID: fid, parentDir: TagScope.parentDir(ofPath: path),
            absolutePath: path, editUpdatedAt: row["edited"])
    }
    return InheritDonor.pick(candidates: candidates, targetDir: targetDir)
}

/// Copy a donor's derived analysis AND user data onto a brand-new row.
/// Derived data is copied rather than recomputed: identical bytes give
/// identical answers, and re-running Vision per duplicate would cost N×.
static func inherit(db: GRDB.Database, from donorID: String,
                    to newID: String, targetDir: String) throws {
    // (Same INSERT…SELECT statements as migration v24 steps 2, 4 and 5,
    //  with donorID in place of oldID. Keep the two in sync — a divergence
    //  means a migrated copy and a newly-indexed copy behave differently.)
}
```

Also update `files.analyzed_hash` on the new row to the donor's, so the copy is not queued for a redundant Vision pass.

- [ ] **Step 8: Run the reconcile tests to verify they pass**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test \
  -only-testing:MuseTests/IndexerReconcileTests 2>&1 | tail -30
```

Expected: PASS. **Pre-existing tests in this file that assert row-sharing or the split behaviour will now fail — that is correct.** Rewrite each to assert the per-file outcome and note in the commit which ones changed and why.

- [ ] **Step 9: Commit**

```bash
git add Muse/Muse/Indexing/ Muse/MuseTests/InheritDonorTests.swift Muse/MuseTests/IndexerReconcileTests.swift
git commit -m "Indexer: a copy is a new file that inherits, never a shared row"
```

---

### Task 3: Analysis reuse — never Vision the same bytes twice

Task 2 inherits at index time. This covers the other door: a file already indexed and awaiting analysis whose bytes match an already-analyzed row.

**Files:**
- Create: `Muse/Muse/Intelligence/AnalysisReuse.swift`
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift` (in `analyzeOne`, before any Vision work)
- Test: `Muse/MuseTests/AnalysisReuseTests.swift`

**Interfaces:**
- Consumes: `Indexer.inherit`'s derived-copy statements.
- Produces: `AnalysisReuse.adopt(db:fileID:hash:) throws -> Bool` — true when a donor's results were copied and Vision can be skipped.

- [ ] **Step 1: Write the failing test**

```swift
func testAdoptsAnAlreadyAnalyzedSiblingsResults() throws {
    // Two files rows, same content_hash. One analyzed (caption, palette,
    // photo_traits, clip_embeddings), one not.
    // Assert adopt() returns true and the second row is fully populated
    // with analyzed_hash == content_hash.
}

func testDoesNotAdoptFromAnUnanalyzedSibling() throws {
    // Sibling has analyzed_hash NULL. Assert adopt() returns false and
    // nothing was written.
}

func testDoesNotAdoptWhenNoSiblingSharesetheHash() throws {
    XCTAssertFalse(try AnalysisReuse.adopt(db: db, fileID: "F", hash: "unique"))
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test \
  -only-testing:MuseTests/AnalysisReuseTests 2>&1 | tail -20
```

Expected: FAIL — `Cannot find 'AnalysisReuse' in scope`.

- [ ] **Step 3: Implement `AnalysisReuse.adopt`**

Select a donor row with the same `content_hash`, a different `id`, and `analyzed_hash = content_hash`; copy the derived columns and rows; set the target's `analyzed_hash`. Return false when there is none.

- [ ] **Step 4: Call it from `analyzeOne`**

At the top of the per-file body, before any decode: if `AnalysisReuse.adopt` returns true, record completion and return. This is what keeps twelve identical RAWs at one Vision pass.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test \
  -only-testing:MuseTests/AnalysisReuseTests 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Intelligence/ Muse/MuseTests/AnalysisReuseTests.swift
git commit -m "Analyze identical bytes once, adopt the result for every copy"
```

---

### Task 4: Migration v25 — drop `parent_dir`

`file_id` now identifies the folder too. The second key column is redundant, and a redundant key column is what let the original bug through.

**Files:**
- Modify: `Muse/Muse/Database/Database.swift` (append v25)
- Modify: `Muse/Muse/Database/TagScope.swift` (delete), `TagStore.swift`, `NoteStore.swift`, `EditRecordStore.swift`, `Indexer.swift` (`unionTags`, `collapseRatings`, `inheritVisionTags`), `Models/EditStore.swift`, and every call site
- Test: `Muse/MuseTests/PerFileIdentityMigrationTests.swift` (extend), plus the existing `TagScope`/note/edit test classes

**Interfaces:**
- Consumes: v24's one-alive-path invariant.
- Produces: `tags(file_id, label)` UNIQUE; `notes(file_id)` PK; `edits(file_id)` PK; `edit_versions` indexed on `file_id`. Every store function loses its `parentDir:` / `fromDir:` / `toDir:` parameter.

- [ ] **Step 1: Write the failing test**

```swift
func testParentDirIsGoneAndDataSurvives() throws {
    // Seed pre-v24 shared rows with tags/notes/edits, migrate fully,
    // assert: no parent_dir column on tags/notes/edits/edit_versions,
    // and each alive path still resolves its own tag/note/edit by file_id.
}
```

Also assert the de-duplication case: two folders' rows for one file are impossible post-v24, so the migration should find at most one row per `file_id` — but write it defensively (keep the newest `updated_at` if two exist) and test that branch.

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test \
  -only-testing:MuseTests/PerFileIdentityMigrationTests 2>&1 | tail -20
```

- [ ] **Step 3: Write migration v25**

Rebuild each of the four tables without `parent_dir`, keeping the row whose `parent_dir` matches its file's alive path (and the newest `updated_at` if somehow two remain). Recreate `edit_versions_scope_idx` on `file_id` alone.

- [ ] **Step 4: Delete the folder parameters**

Remove `parentDir:`/`fromDir:`/`toDir:` from `NoteStore.read/write/applyHydrated/carry`, `EditRecordStore.read/delete/applyHydrated/versions/carry`, `Indexer.unionTags/collapseRatings/inheritVisionTags`. Delete the two per-folder `guard TagScope.parentDir(ofPath: path) == dir` filters in `EditRecordStore.allWithAlivePaths` / `withAlivePaths` — they were compensating for shared rows and are now dead weight. Delete `TagScope.swift` and `EditRecordStore.rewriteParentDirPrefix` (a folder rename no longer rewrites keys; the path row moves and the file_id is unchanged). Let the compiler find the call sites.

- [ ] **Step 5: Run the affected test classes**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test \
  -only-testing:MuseTests/PerFileIdentityMigrationTests \
  -only-testing:MuseTests/TagStoreTests \
  -only-testing:MuseTests/EditRecordStoreTests 2>&1 | tail -30
```

Adjust tests that passed a `parentDir:` argument. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "v25: drop parent_dir — file_id is the folder now"
```

---

### Task 5: Sidecars — one per file, not one per content hash

**Files:**
- Modify: `Muse/Muse/Filesystem/SidecarStore.swift:13-18`
- Test: `Muse/MuseTests/SidecarStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testTwoCopiesInOneFolderGetSeparateSidecars() {
    let a = URL(fileURLWithPath: "/Lib/one.arw")
    let b = URL(fileURLWithPath: "/Lib/one copy.arw")
    XCTAssertNotEqual(SidecarStore.sidecarURL(forAsset: a, contentHash: "H"),
                      SidecarStore.sidecarURL(forAsset: b, contentHash: "H"))
}

func testLegacyHashOnlyNameIsStillReadable() {
    // Write a legacy /Lib/.muse/H.json, assert read(forAsset:contentHash:)
    // still finds it so already-synced libraries keep hydrating.
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test \
  -only-testing:MuseTests/SidecarStoreTests 2>&1 | tail -20
```

Expected: FAIL — both URLs are `/Lib/.muse/H.json`.

- [ ] **Step 3: Implement**

```swift
/// `<asset's folder>/.muse/<content_hash>__<basename>.json`
///
/// The name used to be `<content_hash>.json`, which COLLIDED for two
/// byte-identical files in one folder — they shared one sidecar, so
/// per-file data could not round-trip through sync. Per-file identity
/// makes that a real case rather than a curiosity.
static func sidecarURL(forAsset assetURL: URL, contentHash: String) -> URL {
    assetURL.deletingLastPathComponent()
        .appendingPathComponent(".muse", isDirectory: true)
        .appendingPathComponent("\(contentHash)__\(assetURL.lastPathComponent).json",
                                isDirectory: false)
}

/// The pre-per-file-identity name, still READ so libraries already synced
/// keep hydrating. Never written.
static func legacySidecarURL(forAsset assetURL: URL, contentHash: String) -> URL {
    assetURL.deletingLastPathComponent()
        .appendingPathComponent(".muse", isDirectory: true)
        .appendingPathComponent("\(contentHash).json", isDirectory: false)
}
```

Make `read(forAsset:contentHash:)` try the new name and fall back to the legacy one. `write` uses the new name only.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test \
  -only-testing:MuseTests/SidecarStoreTests 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Filesystem/SidecarStore.swift Muse/MuseTests/SidecarStoreTests.swift
git commit -m "One sidecar per file — the hash-only name collided for same-folder copies"
```

---

### Task 6: Backup — collection membership per occurrence

`BackupOccurrence` already carries tags, note, edit stack and versions per copy. Only membership is per-content.

**Files:**
- Modify: `Muse/Muse/Backup/BackupArchive.swift:17-58`, `BackupBuilder.swift:126-140`, `Muse/Muse/Backup/ReconnectApplier.swift`, `CollectionMaterializer.swift:37`
- Test: `Muse/MuseTests/BackupRoundTripTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testTwoCopiesWithDifferentMembershipRoundTrip() throws {
    // /A/x.jpg in collection C, /A/x copy.jpg NOT in C, same bytes.
    // Build an archive, restore it, assert exactly one is a member.
}

func testPreV26ArchiveStillRestores() throws {
    // An archive with only the per-hash member fields must still restore,
    // putting every copy of that hash in the collection (old semantics).
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test \
  -only-testing:MuseTests/BackupRoundTripTests 2>&1 | tail -20
```

- [ ] **Step 3: Implement**

Add to `BackupOccurrence`:

```swift
/// Collection ids this occurrence belongs to, and the ones it is excluded
/// from. Membership used to ride `BackupCollection.members` keyed on
/// content_hash, which cannot express "this copy is in the collection and
/// its twin is not" — a real case since per-file identity. Optional with a
/// nil default, the archive's standing compatibility mechanism, so
/// pre-existing archives decode unchanged and `currentSchema` stays 1.
var collection_ids: [String]? = nil
var excluded_collection_ids: [String]? = nil
```

Builder writes both. Restore prefers the per-occurrence fields when present, and falls back to the per-hash fields when they are nil.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test \
  -only-testing:MuseTests/BackupRoundTripTests 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Backup/ Muse/MuseTests/BackupRoundTripTests.swift
git commit -m "Backup: collection membership rides the occurrence, not the hash"
```

---

### Task 7: Enforce the invariant, then checkpoint

**Files:**
- Modify: `scripts/audit-invariants.sh`
- Modify: `CLAUDE.md`, `docs/durable-constraints.md`, `docs/session-log.md`, `docs/new-build/FEATURE-LEDGER.md`

- [ ] **Step 1: Add audit check PFI-1**

`content_hash UNIQUE` is gone, so nothing structural stops a future change from re-sharing a row. Add a grep-level check that no `.swift` file reintroduces `parent_dir` in a tags/notes/edits query, and negative-test it by temporarily adding one.

- [ ] **Step 2: Add the runtime invariant test**

In `PerFileIdentityMigrationTests`, assert after a full migrate + a simulated index pass that `MAX(alive paths per file_id) == 1`.

- [ ] **Step 3: Documentation**

- `CLAUDE.md`: one Polish row; update "migrations run through **v25**, so the next spec starts at v26"; add the one-alive-path invariant to the inline critical list (it replaces a `UNIQUE` constraint — breaking it silently re-shares user data).
- `docs/durable-constraints.md` § Indexing & file identity: replace the "shared row must SPLIT on edit-in-place" rule — it is now obsolete — with the per-file identity rule and the donor ordering.
- `docs/session-log.md`: dated entry with the repro, the twelve `.ARW` paths, and what deleted.
- `FEATURE-LEDGER.md`: a row with Runtime **OPEN** and the concrete check (below).

- [ ] **Step 4: THE checkpoint — full unit target, Release build, audit**

This is the one full run for the whole plan.

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests 2>&1 | tail -20
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Release build 2>&1 | grep -E "warning:|error:|BUILD"
./scripts/audit-invariants.sh
```

Expected: suite green, Release warning-free, audit 16/16.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Per-file identity: invariant check, docs, checkpoint"
```

---

## Runtime verification (owner, not automated)

Tests cannot prove this one. On a build with the migration applied:

1. Open `Desktop/Raw Files`. **Expected:** twelve `RAW_SONY_ILCA-77M2*` tiles, and the blue edit badge on only the copies that were edited before — not all twelve.
2. Open one copy, change exposure hard, close. **Expected:** that tile changes; the other eleven do not.
3. Tag one copy "test-a". **Expected:** the tag appears on that tile only.
4. Search `RAW_SONY_ILCA-77M2 copy 7`. **Expected:** it is found — before this change only one of the twelve names was searchable.
5. Add one copy to a collection. **Expected:** one member, not twelve.
6. Watch the status pill during the first launch after migrating. **Expected:** no re-analysis storm — the copies keep their analysis.

**Quit every other Muse instance first.** GRDB's `busyMode` is `.immediateError`; two instances on one database manufacture phantom "my edit didn't save" failures.

## Self-review notes

- **Spec coverage:** §2.1 → tasks 1, 4. §2.2 → tasks 1, 3. §2.3 → tasks 1, 7. §3 → task 2. §4 → tasks 2, 4. §5 → task 1. §6.1 → task 5. §6.2 → task 6. §6.3 → no task needed (verified unchanged). §7 → tests in every task, checkpoint in task 7.
- **Known duplication:** the derived-copy `INSERT…SELECT` statements appear in both migration v24 and `Indexer.inherit`. A migration must be frozen at its historical shape, so they cannot share code; task 2 step 7 calls out keeping them in sync, and task 1's `testDerivedAnalysisIsCopiedToEveryRow` plus task 2's `testNewCopyIsNotMarkedUnanalyzed` guard the two paths independently.
- **Task 2 will break existing tests on purpose.** `IndexerReconcileTests` pins the split-on-edit and hash-collision behaviour, which this plan deletes. Rewriting them is part of task 2, not a regression.
