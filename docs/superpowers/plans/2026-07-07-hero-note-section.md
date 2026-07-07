# Hero viewer per-file Note section — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a user-editable free-text "Note" section to the hero image viewer's info column — per file-location (like tags), searchable, iCloud-synced, and carried through library backup/restore.

**Architecture:** A new `notes(file_id, parent_dir, body)` table (v11 migration) mirrors the tags table's per-location scoping. A pure `NoteStore` enum holds all note DB reads/writes/search so it can be unit-tested with an in-memory queue; `TagStore.setNote` is the thin `@MainActor` write seam the viewer calls (URL → scope → `NoteStore` + sidecar export). Notes are searched via a `LIKE` merge exactly like tags (NOT FTS — `files_fts` is keyed by the immutable `files.id`, which can't represent a per-`(file_id, parent_dir)` value). Sync rides the existing `Sidecar` (new `note` field) and backup/restore rides `BackupOccurrence` (new `note` field), parallel to how tags travel.

**Tech Stack:** Swift 5 / SwiftUI, GRDB (SQLite), XCTest. macOS app, sandboxed.

## Global Constraints

- **Min macOS 14.6.** No API newer than that unless capability-gated.
- **Storage stays canonical-English; localize at DISPLAY time.** Never persist a translated string. Every new user-facing string literal must be extractable (`String(localized:)` or a SwiftUI text-literal position); run `-exportLocalizations` after adding strings and fill the French values.
- **GRDB writes are async:** `try await queue.write { … }` / `try await queue.read { … }`. Rows inserted as `var` (MutablePersistableRecord mutates in place).
- **Notes are per `(file_id, parent_dir)`** — never a `files`/content-hash column (`files.content_hash` is UNIQUE, so one file in two folders could carry two different notes). Same scoping key everywhere: `TagScope.parentDir(of:)` / `TagScope.parentDir(ofPath:)`.
- **Notes are searched via `LIKE`, not FTS.** Do not touch `files_fts` or its three population sites.
- **A note's sidecar merge is non-nil-beats-nil**, not plain last-writer-wins (plain LWW lets an un-hydrated device erase a note).
- **`setNote` must NOT bump `appState.tagsVersion`** (a note has no grid surface).
- **Never bind a `TextField` to a `@Published` `AppState` property.** Note draft lives in local `@State`; write on commit only.
- Build: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj build`. Test: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test`. Single test class: append `-only-testing:MuseTests/<ClassName>`.
- Test DB pattern (used across the suite): `let q = try DatabaseQueue(); try Database.makeMigrator().migrate(q)`, then seed with raw SQL.

---

## File Structure

**Create:**
- `Muse/Muse/Database/NoteStore.swift` — pure `enum NoteStore` with static DB read/write/search functions (the single tested seam).
- `Muse/MuseTests/NoteStoreTests.swift` — unit tests for `NoteStore` + the v11 migration.

**Modify:**
- `Muse/Muse/Database/Database.swift` — add `v11_file_note` migration (~after line 338).
- `Muse/Muse/Database/Records.swift` — add `NoteRow` (~after `TagRow`, line 83).
- `Muse/Muse/Database/TagStore.swift` — add `setNote(_:forURL:)` + `note(for:)` (~after `setRating`, line 258).
- `Muse/Muse/Views/Viewer/ViewerFileDetails.swift` — add `note` field + read.
- `Muse/Muse/Views/Viewer/ViewerInfoColumn.swift` — add the Note card, state, save timing, copy button.
- `Muse/Muse/Database/SearchService.swift` — merge `NoteStore.search` IDs into `exactIDs` (~line 55).
- `Muse/Muse/Filesystem/Sidecar.swift` — add `note` field, extend `build`, add merge rule.
- `Muse/Muse/Intelligence/AnalyzePipeline.swift` — fetch + pass note in `writeSidecarIfICloud` (~line 300-311).
- `Muse/Muse/Filesystem/SidecarHydrator.swift` — apply incoming `note` (~after line 64).
- `Muse/Muse/Backup/BackupArchive.swift` — add `note` to `BackupOccurrence` (line 22).
- `Muse/Muse/Backup/BackupBuilder.swift` — build `noteByFileDir`, set on occurrence (~line 32-64).
- `Muse/Muse/Backup/ReconnectApplier.swift` — apply `occurrence.note` (~after line 53).
- `Muse/MuseTests/SidecarTests.swift`, `Muse/MuseTests/BackupArchiveTests.swift`, `Muse/MuseTests/ReconnectApplierTests.swift` — extend with note cases.
- `Muse/Muse/Localizable.xcstrings` — French values for new strings (via `-exportLocalizations`).

---

## Task 1: `notes` table + `NoteRow` + `NoteStore` (the tested storage core)

**Files:**
- Modify: `Muse/Muse/Database/Database.swift` (add migration after line 338)
- Modify: `Muse/Muse/Database/Records.swift` (add `NoteRow` after line 83)
- Create: `Muse/Muse/Database/NoteStore.swift`
- Test: `Muse/MuseTests/NoteStoreTests.swift`

**Interfaces:**
- Produces:
  - Migration `"v11_file_note"` creating table `notes(file_id TEXT, parent_dir TEXT, body TEXT, updated_at INTEGER, PK(file_id,parent_dir), FK file_id → files ON DELETE CASCADE)`.
  - `struct NoteRow: Codable, FetchableRecord, MutablePersistableRecord` (table `notes`).
  - `enum NoteStore` with:
    - `static func read(fileID: String, parentDir: String, db: GRDB.Database) throws -> String?`
    - `static func write(_ body: String, fileID: String, parentDir: String, updatedAt: Int64, db: GRDB.Database) throws` — trims; empty/whitespace body deletes the row; else upserts.
    - `static func searchIDs(term: String, db: GRDB.Database) throws -> [String]` — distinct `file_id`s whose `body LIKE %term%` (LIKE-escaped); empty term → `[]`.

- [ ] **Step 1: Write the failing tests**

Create `Muse/MuseTests/NoteStoreTests.swift`:

```swift
//
//  NoteStoreTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class NoteStoreTests: XCTestCase {
    /// A migrated queue with two files, each with an alive path in a distinct folder,
    /// plus a duplicate of file A living in a second folder (same file_id is NOT the
    /// case here — notes are keyed by (file_id, parent_dir), so we seed two folders
    /// under one file_id to prove scope isolation).
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f2','h2','image',0)")
        }
        return q
    }

    func testMigrationCreatesNotesTable() throws {
        let q = try makeQueue()
        let exists = try q.read { db in
            try Bool.fetchOne(db, sql:
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='notes'") ?? false
        }
        XCTAssertTrue(exists)
    }

    func testWriteThenReadRoundTrips() throws {
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("hello world", fileID: "f1", parentDir: "/A", updatedAt: 10, db: db)
        }
        let body = try q.read { db in try NoteStore.read(fileID: "f1", parentDir: "/A", db: db) }
        XCTAssertEqual(body, "hello world")
    }

    func testWriteReplacesExisting() throws {
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("first", fileID: "f1", parentDir: "/A", updatedAt: 10, db: db)
            try NoteStore.write("second", fileID: "f1", parentDir: "/A", updatedAt: 11, db: db)
        }
        let body = try q.read { db in try NoteStore.read(fileID: "f1", parentDir: "/A", db: db) }
        XCTAssertEqual(body, "second")
        let count = try q.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes")! }
        XCTAssertEqual(count, 1)
    }

    func testEmptyBodyDeletesRow() throws {
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("something", fileID: "f1", parentDir: "/A", updatedAt: 10, db: db)
            try NoteStore.write("   ", fileID: "f1", parentDir: "/A", updatedAt: 11, db: db)
        }
        let body = try q.read { db in try NoteStore.read(fileID: "f1", parentDir: "/A", db: db) }
        XCTAssertNil(body)
    }

    func testScopeIsolationSameFileTwoFolders() throws {
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("note in A", fileID: "f1", parentDir: "/A", updatedAt: 10, db: db)
            try NoteStore.write("note in B", fileID: "f1", parentDir: "/B", updatedAt: 10, db: db)
        }
        let a = try q.read { db in try NoteStore.read(fileID: "f1", parentDir: "/A", db: db) }
        let b = try q.read { db in try NoteStore.read(fileID: "f1", parentDir: "/B", db: db) }
        XCTAssertEqual(a, "note in A")
        XCTAssertEqual(b, "note in B")
    }

    func testSearchMatchesSubstringReturnsFileID() throws {
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("a memo about ducks", fileID: "f1", parentDir: "/A", updatedAt: 10, db: db)
            try NoteStore.write("unrelated", fileID: "f2", parentDir: "/B", updatedAt: 10, db: db)
        }
        let ids = try q.read { db in try NoteStore.searchIDs(term: "duck", db: db) }
        XCTAssertEqual(ids, ["f1"])
    }

    func testSearchEmptyTermReturnsNothing() throws {
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("anything", fileID: "f1", parentDir: "/A", updatedAt: 10, db: db)
        }
        let ids = try q.read { db in try NoteStore.searchIDs(term: "   ", db: db) }
        XCTAssertTrue(ids.isEmpty)
    }

    func testSearchWildcardIsLiteral() throws {
        // A note without a literal % must not match a "%" query (LIKE escaping).
        let q = try makeQueue()
        try q.write { db in
            try NoteStore.write("plain text", fileID: "f1", parentDir: "/A", updatedAt: 10, db: db)
        }
        let ids = try q.read { db in try NoteStore.searchIDs(term: "%", db: db) }
        XCTAssertTrue(ids.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test -only-testing:MuseTests/NoteStoreTests`
Expected: FAIL — `notes` table missing / `NoteStore` undefined / `NoteRow` undefined.

- [ ] **Step 3: Add the v11 migration**

In `Muse/Muse/Database/Database.swift`, immediately after the `v10_collection_appearance` block (after line 338, before `return migrator`):

```swift
        migrator.registerMigration("v11_file_note") { db in
            // A user-authored free-text note, per file-LOCATION (file_id, parent_dir)
            // like tags — never a files/content-hash column (files.content_hash is
            // UNIQUE, so one file in two folders could carry two different notes).
            // Absence of a row = "no note"; an emptied note deletes its row.
            try db.create(table: "notes") { t in
                t.column("file_id", .text).notNull()
                t.column("parent_dir", .text).notNull()
                t.column("body", .text).notNull()
                t.column("updated_at", .integer).notNull()
                t.primaryKey(["file_id", "parent_dir"])
                t.foreignKey(["file_id"], references: "files", columns: ["id"], onDelete: .cascade)
            }
        }
```

- [ ] **Step 4: Add the `NoteRow` record**

In `Muse/Muse/Database/Records.swift`, after the `TagRow` struct (after line 83):

```swift
struct NoteRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "notes"

    /// File this note belongs to, scoped to its folder — notes are per-location
    /// like tags (a duplicate in another folder has its own note).
    var file_id: String
    var parent_dir: String
    var body: String
    /// Epoch seconds of the last write; feeds the sidecar's last-writer-wins.
    var updated_at: Int64

    enum Columns {
        static let file_id = Column("file_id")
        static let parent_dir = Column("parent_dir")
        static let body = Column("body")
    }
}
```

- [ ] **Step 5: Create `NoteStore`**

Create `Muse/Muse/Database/NoteStore.swift`:

```swift
//
//  NoteStore.swift
//  Muse
//
//  Pure DB read/write/search for the notes table. A note belongs to a file IN
//  A FOLDER: identity is (file_id, parent_dir), exactly like tags. These are
//  free/`nonisolated` static functions taking a GRDB `Database` so they can run
//  inside any read/write closure and be unit-tested with an in-memory queue.
//  The @MainActor write seam the UI calls is `TagStore.setNote`.
//

import Foundation
import GRDB

nonisolated enum NoteStore {
    /// The note body for a (file_id, parent_dir), or nil if there is none.
    static func read(fileID: String, parentDir: String, db: GRDB.Database) throws -> String? {
        try String.fetchOne(db, sql:
            "SELECT body FROM notes WHERE file_id = ? AND parent_dir = ?",
            arguments: [fileID, parentDir])
    }

    /// Upsert the note for a (file_id, parent_dir). A blank/whitespace body
    /// DELETES the row ("no note" is the absence of a row, never an empty string).
    static func write(_ body: String, fileID: String, parentDir: String,
                      updatedAt: Int64, db: GRDB.Database) throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try db.execute(sql: "DELETE FROM notes WHERE file_id = ? AND parent_dir = ?",
                           arguments: [fileID, parentDir])
            return
        }
        try db.execute(sql: """
            INSERT INTO notes (file_id, parent_dir, body, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(file_id, parent_dir) DO UPDATE SET
                body = excluded.body, updated_at = excluded.updated_at
            """, arguments: [fileID, parentDir, trimmed, updatedAt])
    }

    /// Distinct file_ids whose note body contains `term` (case-insensitive
    /// substring). Empty term → no matches. Mirrors the tag LIKE search path;
    /// notes are NOT in FTS (files_fts is keyed by the immutable files.id, which
    /// can't represent a per-(file_id, parent_dir) value).
    static func searchIDs(term: String, db: GRDB.Database) throws -> [String] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pattern = "%" + likeEscape(trimmed) + "%"
        return try String.fetchAll(db, sql: """
            SELECT DISTINCT file_id FROM notes WHERE body LIKE ? ESCAPE '\\'
            """, arguments: [pattern])
    }

    /// Escape LIKE metacharacters so a user query is matched literally.
    private static func likeEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test -only-testing:MuseTests/NoteStoreTests`
Expected: PASS (all 8 tests).

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Database/NoteStore.swift Muse/MuseTests/NoteStoreTests.swift Muse/Muse/Database/Database.swift Muse/Muse/Database/Records.swift
git commit -m "feat: notes table + NoteStore (per-file note storage core)"
```

---

## Task 2: `TagStore.setNote` write seam + `ViewerFileDetails.note` read

**Files:**
- Modify: `Muse/Muse/Database/TagStore.swift` (after `setRating`, line 258)
- Modify: `Muse/Muse/Views/Viewer/ViewerFileDetails.swift`
- Test: `Muse/MuseTests/ViewerFileDetailsNoteTests.swift` (new)

**Interfaces:**
- Consumes: `NoteStore.read/write` (Task 1), `TagScope.parentDir(of:)`, `tagScopes(forPaths:db:)` (existing, TagStore.swift:18), `AnalyzePipeline.shared.exportSidecarsAfterTagEdit(for:)` (existing).
- Produces:
  - `TagStore.setNote(_ body: String, forURL url: URL) async` — resolves URL → (file_id, parent_dir), writes via `NoteStore`, exports sidecar. Does NOT bump `tagsVersion`.
  - `TagStore.note(for url: URL) async -> String` — "" when none.
  - `ViewerFileDetails.note: String` populated by `load`.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/ViewerFileDetailsNoteTests.swift`:

```swift
//
//  ViewerFileDetailsNoteTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class ViewerFileDetailsNoteTests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/Pics/cat.jpg',1)")
        }
        return q
    }

    func testLoadReturnsNote() async throws {
        let q = try makeQueue()
        try await q.write { db in
            try NoteStore.write("a cat nap", fileID: "f1", parentDir: "/Pics", updatedAt: 5, db: db)
        }
        let details = try await ViewerFileDetails.load(queue: q, path: "/Pics/cat.jpg")
        XCTAssertEqual(details?.note, "a cat nap")
    }

    func testLoadReturnsEmptyWhenNoNote() async throws {
        let q = try makeQueue()
        let details = try await ViewerFileDetails.load(queue: q, path: "/Pics/cat.jpg")
        XCTAssertEqual(details?.note, "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test -only-testing:MuseTests/ViewerFileDetailsNoteTests`
Expected: FAIL — `ViewerFileDetails` has no `note` member.

- [ ] **Step 3: Add `note` to `ViewerFileDetails`**

In `Muse/Muse/Views/Viewer/ViewerFileDetails.swift`, add the stored property (after line 12, `var collections: [CollectionRow]`):

```swift
    var collections: [CollectionRow]
    /// User-authored note for this file IN THIS FOLDER ("" if none).
    var note: String
```

Then in `load`, read it alongside tags. After the `tags` fetch (line 31) and before `let cols`:

```swift
            let note = try NoteStore.read(fileID: fid, parentDir: dir, db: db) ?? ""
```

And add `note: note` to the returned initializer (line 39-41):

```swift
            return ViewerFileDetails(fileID: fid, pixelSize: size, sizeBytes: f.size_bytes,
                                     dominantColor: f.dominant_color, palette: palette,
                                     tags: tags, collections: cols, note: note)
```

- [ ] **Step 4: Add `setNote` / `note` to `TagStore`**

In `Muse/Muse/Database/TagStore.swift`, after `setRating` (after line 258, before `removeTag`):

```swift
    /// Read the note for a file IN ITS FOLDER ("" if none / not indexed).
    func note(for url: URL) async -> String {
        guard let queue = Database.shared.dbQueue else { return "" }
        let absPath = url.standardizedFileURL.path
        let dir = TagScope.parentDir(ofPath: absPath)
        return ((try? await queue.read { db -> String? in
            guard let path = try PathRow
                    .filter(PathRow.Columns.absolute_path == absPath)
                    .filter(PathRow.Columns.is_alive == 1)
                    .fetchOne(db),
                  let fileID = path.file_id else { return nil }
            return try NoteStore.read(fileID: fileID, parentDir: dir, db: db)
        }) ?? nil) ?? ""
    }

    /// Set (or clear, when blank) the note for a file IN ITS FOLDER. Scoped to
    /// (file_id, parent_dir) like tags. Like every TagStore mutation it re-exports
    /// the iCloud sidecar. DELIBERATELY does NOT bump `AppState.tagsVersion` — a
    /// note has no grid surface, so re-evaluating grid chips/counts is wasted work.
    func setNote(_ body: String, forURL url: URL) async {
        guard let queue = Database.shared.dbQueue else { return }
        let absPath = url.standardizedFileURL.path
        let now = Int64(Date().timeIntervalSince1970)
        do {
            try await queue.write { db in
                for scope in try tagScopes(forPaths: [absPath], db: db) {
                    try NoteStore.write(body, fileID: scope.fileID,
                                        parentDir: scope.dir, updatedAt: now, db: db)
                }
            }
        } catch {
            print("[TagStore] setNote failed: \(error)")
        }
        AnalyzePipeline.shared.exportSidecarsAfterTagEdit(for: [url])
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test -only-testing:MuseTests/ViewerFileDetailsNoteTests`
Expected: PASS (both tests).

- [ ] **Step 6: Build the whole app (the `ViewerFileDetails` initializer gained a param — verify no other call site broke)**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj build`
Expected: BUILD SUCCEEDED. (If a `ViewerFileDetails(...)` call elsewhere fails to compile, add `note: ""` there.)

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Database/TagStore.swift Muse/Muse/Views/Viewer/ViewerFileDetails.swift Muse/MuseTests/ViewerFileDetailsNoteTests.swift
git commit -m "feat: TagStore.setNote/note write seam + ViewerFileDetails.note"
```

---

## Task 3: Note card UI in the hero viewer

**Files:**
- Modify: `Muse/Muse/Views/Viewer/ViewerInfoColumn.swift`
- Modify: `Muse/Muse/Localizable.xcstrings` (via export tool)

**Interfaces:**
- Consumes: `TagStore.shared.setNote(_:forURL:)` (Task 2), `details?.note` (Task 2), existing `InfoCard`, `CardLabel`, `PlusCircleButton`, `refresh`, `copyToPasteboard`, `show`.
- Produces: a `noteCard` view + `@State` (`noteExpanded`, `noteDraft`, `loadedNote`, `@FocusState noteFocused`) and a `commitNote(to:)` helper.

*No unit test — this is SwiftUI view code (the suite has no UI tests). Verified at runtime in Step 6.*

- [ ] **Step 1: Add note state**

In `Muse/Muse/Views/Viewer/ViewerInfoColumn.swift`, add to the `@State` block (after line 55, `@State private var tagSuggestions`):

```swift
    /// Note card: default collapsed when empty, expanded when it has text.
    @State private var noteExpanded = false
    /// Local draft — never bound to AppState. Committed on blur / collapse / file switch.
    @State private var noteDraft = ""
    /// The note value we last seeded the draft from, so commit only writes on change.
    @State private var loadedNote = ""
    @FocusState private var noteFocused: Bool
```

- [ ] **Step 2: Insert the card into the layout**

In `body`, add `noteCard` between `ratingCard` and the colors card (after line 65, `ratingCard`):

```swift
                ratingCard
                noteCard
                if !displayPalette.isEmpty {
```

- [ ] **Step 3: Implement `noteCard`**

Add after `ratingCard`/`setRating` (after line 300), before `// MARK: - Colors card`:

```swift
    // MARK: - Note card

    /// A user-authored free-text note, per file-in-folder. Collapsible (default
    /// collapsed when empty, expanded when it has text). The draft is local and
    /// commits on blur / collapse / file switch — never per keystroke.
    private var noteCard: some View {
        InfoCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardLabel(text: String(localized: "NOTE"))
                    Spacer()
                    Button {
                        copyToPasteboard(noteDraft)
                        show(String(localized: "Note copied"))
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(String(localized: "Copy note"))
                    PlusCircleButton(size: 18, rotated: noteExpanded,
                                     accessibilityLabel: noteExpanded ? String(localized: "Hide note")
                                                                      : String(localized: "Show note")) {
                        // Collapsing commits any pending edit first.
                        if noteExpanded { commitNote(to: url) }
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                            noteExpanded.toggle()
                        }
                    }
                }
                if noteExpanded {
                    TextField(String(localized: "Add a note…"), text: $noteDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...8)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(0.08)))
                        .focused($noteFocused)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Seed the draft when the loaded note changes (details arrive async after
        // a file switch). Don't stomp an in-progress edit.
        .onChange(of: details?.note) { _, newValue in
            let value = newValue ?? ""
            loadedNote = value
            if !noteFocused {
                noteDraft = value
                noteExpanded = !value.isEmpty
            }
        }
        // File switched (e.g. arrow keys) while editing: flush to the OLD file first.
        .onChange(of: url) { oldURL, _ in
            commitNote(to: oldURL)
        }
        // Blur commits.
        .onChange(of: noteFocused) { _, focused in
            if !focused { commitNote(to: url) }
        }
        .onDisappear { commitNote(to: url) }
    }

    /// Write the draft to `target` only if it changed from the loaded value.
    private func commitNote(to target: URL) {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != loadedNote.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        loadedNote = trimmed
        Task {
            await TagStore.shared.setNote(trimmed, forURL: target)
            await refresh()
        }
    }
```

- [ ] **Step 4: Seed the draft on first open**

The `.onChange(of: details?.note)` handler covers subsequent loads, but the very first `details` may already be set when the card mounts. Add a `.task(id: url)` seed on the card (append after `.onDisappear` in Step 3):

```swift
        .task(id: url) {
            let value = details?.note ?? ""
            loadedNote = value
            noteDraft = value
            noteExpanded = !value.isEmpty
        }
```

- [ ] **Step 5: Export + fill localization**

Run: `xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj -localizationPath /tmp/muse-loc -exportLanguage fr`

Then in `Muse/Muse/Localizable.xcstrings`, fill the French values for the new keys (the export write-backs the keys; add translations):
- `"NOTE"` → `"NOTE"`
- `"Add a note…"` → `"Ajouter une note…"`
- `"Copy note"` → `"Copier la note"`
- `"Note copied"` → `"Note copiée"`
- `"Show note"` → `"Afficher la note"`
- `"Hide note"` → `"Masquer la note"`

- [ ] **Step 6: Build and verify at runtime**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj build`
Expected: BUILD SUCCEEDED.

Then run the app (Cmd+R in Xcode or launch the built product) and verify:
- Open an image → zoom → the info column shows a **NOTE** card between RATING and COLORS, collapsed (no text yet).
- Expand, type a note, click away (blur) → reopen the same image → the card is **expanded** and shows the note.
- The copy button copies the text (paste elsewhere to confirm); it's disabled when empty.
- Collapse/expand toggles; collapsing after an edit saves.
- Arrow to another image while a note field is focused → the edit lands on the correct (previous) file, and the new file shows its own note.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Views/Viewer/ViewerInfoColumn.swift Muse/Muse/Localizable.xcstrings
git commit -m "feat: Note card in the hero viewer (collapsible, copy, per-file)"
```

---

## Task 4: Search — merge note matches into results

**Files:**
- Modify: `Muse/Muse/Database/SearchService.swift` (~line 55)

**Interfaces:**
- Consumes: `NoteStore.searchIDs(term:db:)` (Task 1).
- Produces: note-matched `file_id`s folded into `exactIDs` (so a note substring surfaces the file, scope-filtered like all other hits).

*Covered by `NoteStoreTests.testSearchMatchesSubstringReturnsFileID` (the match logic) + runtime verify (the wiring). `SearchService.search` is `@MainActor` and pulls in the embedder + a folder stat sweep, so it isn't unit-tested end-to-end in the suite.*

- [ ] **Step 1: Add the note match block**

In `Muse/Muse/Database/SearchService.swift`, inside the `queue.read` closure, after the tag-match block that ends at line 54 (`.map { $0.file_id }`) and before the "Exact hits, ordered" comment (line 56):

```swift
            // 2b) Note substring matches (per (file_id, parent_dir), LIKE — notes
            //     are not in FTS). Uses the raw trimmed query, same as basename/OCR.
            let noteIDs = try NoteStore.searchIDs(term: trimmed, db: db)
```

Then extend the exact-hits merge loop (currently `for id in ftsIDs + tagIDs`) at line 60 to include `noteIDs`:

```swift
            var exactSeen = Set<String>()
            var exactIDs: [String] = []
            for id in ftsIDs + tagIDs + noteIDs where !exactSeen.contains(id) {
                exactIDs.append(id); exactSeen.insert(id)
            }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Verify at runtime**

Run the app: add a note containing a distinctive word to an image, then type that word in the search field. The image appears in results. Switch scope to This Folder / All and confirm scope filtering still applies (a note match in another folder doesn't appear under This-Folder scope).

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Database/SearchService.swift
git commit -m "feat: notes are searchable (LIKE merge, like tags)"
```

---

## Task 5: iCloud sidecar sync for the note

**Files:**
- Modify: `Muse/Muse/Filesystem/Sidecar.swift`
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift` (~line 300-311)
- Modify: `Muse/Muse/Filesystem/SidecarHydrator.swift` (~after line 64)
- Test: `Muse/MuseTests/SidecarTests.swift`

**Interfaces:**
- Consumes: `NoteStore.read/write` (Task 1).
- Produces: `Sidecar.note: String?`; `Sidecar.build(..., note:)`; a non-nil-beats-nil merge for `note`; sidecar write carries the note; hydrate applies an incoming note.

- [ ] **Step 1: Write the failing tests**

In `Muse/MuseTests/SidecarTests.swift`, add (adapt the existing `make(...)` helper if present; otherwise these are self-contained):

```swift
    func testNoteSurvivesJSONRoundTrip() throws {
        let s = Sidecar(schema: 1, updated_at: 1, content_hash: "h", kind: "image",
                        width: nil, height: nil, duration_seconds: nil, created_at: nil,
                        modified_at: nil, caption: nil, dominant_color: nil, palette: nil,
                        feature_print: nil, analyzed_hash: nil, intent: nil,
                        intent_model_version: nil, tags: [], note: "remember this")
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Sidecar.self, from: data)
        XCTAssertEqual(back.note, "remember this")
    }

    func testOldSidecarWithoutNoteDecodesAsNil() throws {
        // JSON from before the note field existed (no "note" key).
        let json = """
        {"schema":1,"updated_at":1,"content_hash":"h","kind":"image","tags":[]}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Sidecar.self, from: json)
        XCTAssertNil(s.note)
    }

    func testMergeNonNilNoteNeverClobberedByNil() {
        // a = on-disk (has a note); b = fresh from a device that never hydrated it (nil).
        let a = Sidecar(schema: 1, updated_at: 5, content_hash: "h", kind: "image",
                        width: nil, height: nil, duration_seconds: nil, created_at: nil,
                        modified_at: nil, caption: nil, dominant_color: nil, palette: nil,
                        feature_print: nil, analyzed_hash: nil, intent: nil,
                        intent_model_version: nil, tags: [], note: "keep me")
        let b = Sidecar(schema: 1, updated_at: 9, content_hash: "h", kind: "image",
                        width: nil, height: nil, duration_seconds: nil, created_at: nil,
                        modified_at: nil, caption: nil, dominant_color: nil, palette: nil,
                        feature_print: nil, analyzed_hash: nil, intent: nil,
                        intent_model_version: nil, tags: [], note: nil)
        XCTAssertEqual(Sidecar.merge(a, b).note, "keep me")
    }

    func testMergeFreshNoteWinsBetweenTwoNonNil() {
        let a = Sidecar(schema: 1, updated_at: 5, content_hash: "h", kind: "image",
                        width: nil, height: nil, duration_seconds: nil, created_at: nil,
                        modified_at: nil, caption: nil, dominant_color: nil, palette: nil,
                        feature_print: nil, analyzed_hash: nil, intent: nil,
                        intent_model_version: nil, tags: [], note: "old")
        let b = Sidecar(schema: 1, updated_at: 9, content_hash: "h", kind: "image",
                        width: nil, height: nil, duration_seconds: nil, created_at: nil,
                        modified_at: nil, caption: nil, dominant_color: nil, palette: nil,
                        feature_print: nil, analyzed_hash: nil, intent: nil,
                        intent_model_version: nil, tags: [], note: "new")
        XCTAssertEqual(Sidecar.merge(a, b).note, "new")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test -only-testing:MuseTests/SidecarTests`
Expected: FAIL — `Sidecar` has no `note` parameter.

- [ ] **Step 3: Add `note` to `Sidecar` + `build` + merge rule**

In `Muse/Muse/Filesystem/Sidecar.swift`:

Add the field as the LAST stored property (after line 42, `var tags: [SidecarTag]`), defaulted so existing positional/memberwise callers still compile and old JSON decodes to nil:

```swift
    var tags: [SidecarTag]
    /// User-authored note, per (file_id, parent_dir). Optional so pre-note
    /// sidecars decode to nil. NOT a FileRow column (`apply` never touches it).
    var note: String? = nil
```

Extend `build` (line 50) with a defaulted `note` param and pass it through:

```swift
    static func build(from file: FileRow, tags: [TagRow], updatedAt: Int64,
                      note: String? = nil) -> Sidecar? {
        guard let hash = file.content_hash else { return nil }
        return Sidecar(
            schema: Sidecar.currentSchema,
            updated_at: updatedAt,
            content_hash: hash,
            kind: file.kind,
            width: file.width,
            height: file.height,
            duration_seconds: file.duration_seconds,
            created_at: file.created_at,
            modified_at: file.modified_at,
            caption: file.caption,
            dominant_color: file.dominant_color,
            palette: file.palette,
            feature_print: file.feature_print,
            analyzed_hash: file.analyzed_hash,
            intent: file.intent,
            intent_model_version: file.intent_model_version,
            tags: tags.map {
                SidecarTag(label: $0.label, source: $0.source,
                           confidence: $0.confidence, model_version: $0.model_version)
            },
            note: note
        )
    }
```

Add the merge rule inside `merge` (after line 114, `winner.tags = mergeTags(...)`):

```swift
        winner.tags = mergeTags(a.tags, b.tags)
        // A note is a scalar with no union; plain LWW would let a newer
        // analyze-export from a device that never hydrated the note clobber it
        // with nil. b is the fresh (DB-derived) side at the call site
        // `merge(existing, sidecar)`: a non-nil note is never overwritten by nil,
        // and between two non-nil the fresh side wins. Genuine deletions travel
        // the manual-edit path (mergeExisting: false), which bypasses merge.
        winner.note = b.note ?? a.note
        return winner
```

- [ ] **Step 4: Carry the note in the sidecar write path**

In `Muse/Muse/Intelligence/AnalyzePipeline.swift`, `writeSidecarIfICloud`: extend the read bundle to also fetch the note, and pass it to `build`.

Change the bundle type + read (lines 300-309) to include the note:

```swift
        let bundle: (FileRow, [TagRow], String?)? = try? await queue.read { db -> (FileRow, [TagRow], String?)? in
            guard let file = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db)
            else { return nil }
            // Sidecar lives in this file's folder → carry only this folder's tags + note.
            let tags = try TagRow
                .filter(TagRow.Columns.file_id == fileID)
                .filter(TagRow.Columns.parent_dir == dir)
                .fetchAll(db)
            let note = try NoteStore.read(fileID: fileID, parentDir: dir, db: db)
            return (file, tags, note)
        }
        guard let (file, tags, note) = bundle,
              let sidecar = Sidecar.build(from: file, tags: tags, updatedAt: now, note: note) else { return }
```

- [ ] **Step 5: Apply an incoming note on hydrate**

In `Muse/Muse/Filesystem/SidecarHydrator.swift`, `apply`, inside the `queue.write` after the tag loop (after line 64, before the FTS block at line 65):

```swift
            // Note: upsert the incoming note for this folder (nil/empty deletes).
            try NoteStore.write(sidecar.note ?? "", fileID: fileID,
                                parentDir: parentDir, updatedAt: sidecar.updated_at, db: db)
```

- [ ] **Step 6: Run the sidecar tests + build**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test -only-testing:MuseTests/SidecarTests`
Expected: PASS (existing + 4 new).

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Filesystem/Sidecar.swift Muse/Muse/Intelligence/AnalyzePipeline.swift Muse/Muse/Filesystem/SidecarHydrator.swift Muse/MuseTests/SidecarTests.swift
git commit -m "feat: note rides the iCloud sidecar (non-nil-beats-nil merge)"
```

---

## Task 6: Library backup / restore for the note

**Files:**
- Modify: `Muse/Muse/Backup/BackupArchive.swift` (line 22)
- Modify: `Muse/Muse/Backup/BackupBuilder.swift` (~line 32-64)
- Modify: `Muse/Muse/Backup/ReconnectApplier.swift` (~after line 53)
- Test: `Muse/MuseTests/BackupArchiveTests.swift`, `Muse/MuseTests/ReconnectApplierTests.swift`

**Interfaces:**
- Consumes: `NoteStore.read/write` (Task 1).
- Produces: `BackupOccurrence.note: String?`; builder attaches per-location note; restore applies it at the new `parent_dir`.

- [ ] **Step 1: Write the failing tests**

In `Muse/MuseTests/ReconnectApplierTests.swift`, extend the `archive()` helper's occurrence to carry a note, and add a test. Change the `occ` in `archive()` (lines 29-32) to include `note`:

```swift
        let occ = BackupOccurrence(original_path: "/old/Pics/cat.jpg", basename: "cat.jpg",
                                   root_path: "/old/Pics", parent_dir: "/old/Pics",
                                   tags: [SidecarTag(label: "cat", source: "manual",
                                                     confidence: nil, model_version: nil)],
                                   note: "a note about this cat")
```

Add a test:

```swift
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
```

In `Muse/MuseTests/BackupArchiveTests.swift`, add a round-trip + old-decode test (adapt to that file's existing style):

```swift
    func testBackupOccurrenceNoteRoundTrips() throws {
        let occ = BackupOccurrence(original_path: "/p/x.jpg", basename: "x.jpg",
                                   root_path: "/p", parent_dir: "/p", tags: [], note: "hi")
        let data = try JSONEncoder().encode(occ)
        let back = try JSONDecoder().decode(BackupOccurrence.self, from: data)
        XCTAssertEqual(back.note, "hi")
    }

    func testOldOccurrenceWithoutNoteDecodesAsNil() throws {
        let json = """
        {"original_path":"/p/x.jpg","basename":"x.jpg","tags":[]}
        """.data(using: .utf8)!
        let back = try JSONDecoder().decode(BackupOccurrence.self, from: json)
        XCTAssertNil(back.note)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test -only-testing:MuseTests/ReconnectApplierTests -only-testing:MuseTests/BackupArchiveTests`
Expected: FAIL — `BackupOccurrence` has no `note` parameter.

- [ ] **Step 3: Add `note` to `BackupOccurrence`**

In `Muse/Muse/Backup/BackupArchive.swift`, add as the LAST field of `BackupOccurrence` (after line 22, `var tags: [SidecarTag]`), defaulted so old archives decode:

```swift
    var tags: [SidecarTag]
    /// User-authored note for this occurrence's (file_id, parent_dir). Optional
    /// so pre-note archives decode. Notes ride the occurrence, NOT meta (per-location).
    var note: String? = nil
```

- [ ] **Step 4: Attach the note when building the archive**

In `Muse/Muse/Backup/BackupBuilder.swift`, build a note map alongside `tagsByFileDir`. After the tags-grouping block (after line 40):

```swift
            // Notes grouped by (file_id, parent_dir), same key shape as tags.
            let noteRows = try NoteRow.fetchAll(db)
            var noteByFileDir: [String: String] = [:]
            for n in noteRows {
                noteByFileDir["\(n.file_id)\u{1}\(n.parent_dir)"] = n.body
            }
```

Then set `note:` on the `BackupOccurrence` (line 59-64):

```swift
                    return BackupOccurrence(
                        original_path: p.absolute_path,
                        basename: url.lastPathComponent,
                        root_path: rootPath,
                        parent_dir: parent,
                        tags: tagsByFileDir["\(fid)\u{1}\(parent)"] ?? [],
                        note: noteByFileDir["\(fid)\u{1}\(parent)"])
```

- [ ] **Step 5: Apply the note on restore**

In `Muse/Muse/Backup/ReconnectApplier.swift`, `applyMeta`, inside the `queue.write` after the tag loop (after line 53, before the FTS mirror at line 54):

```swift
                // Note: apply the occurrence's note at the NEW parent_dir.
                if let body = m.occurrence.note {
                    try NoteStore.write(body, fileID: fid, parentDir: parentDir,
                                        updatedAt: Int64(Date().timeIntervalSince1970), db: db)
                }
```

- [ ] **Step 6: Run tests + build**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test -only-testing:MuseTests/ReconnectApplierTests -only-testing:MuseTests/BackupArchiveTests`
Expected: PASS.

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Full test suite (guard against regressions in Sidecar/Backup call sites)**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test`
Expected: All tests PASS.

- [ ] **Step 8: Commit**

```bash
git add Muse/Muse/Backup/BackupArchive.swift Muse/Muse/Backup/BackupBuilder.swift Muse/Muse/Backup/ReconnectApplier.swift Muse/MuseTests/ReconnectApplierTests.swift Muse/MuseTests/BackupArchiveTests.swift
git commit -m "feat: note rides library backup/restore (per-occurrence)"
```

---

## Task 7: Docs — record the durable constraints

**Files:**
- Modify: `CLAUDE.md` (Durable constraints & gotchas)
- Modify: `docs/session-log.md` (new dated entry)

- [ ] **Step 1: Add a durable-constraints bullet**

In `CLAUDE.md`, under "Durable constraints & gotchas", add:

```markdown
- **A per-file NOTE is per `(file_id, parent_dir)` like tags — never a `files`/content-hash column** (`files.content_hash` is UNIQUE, so one file in two folders could carry two different notes). Stored in the `notes` table (`v11_file_note`), read/written through the pure `NoteStore` (the tested seam) with `TagStore.setNote` as the `@MainActor` write path. **Searched via `LIKE` (merged into `exactIDs`), NOT FTS** — `files_fts` is keyed by the immutable `files.id`, which can't represent a per-location value. Its sidecar merge is **non-nil-beats-nil** (`winner.note = b.note ?? a.note`), not plain LWW — plain LWW lets a newer analyze-export from a device that never hydrated the note erase it with nil (deletions still propagate via the manual-edit `mergeExisting:false` path). `setNote` deliberately does NOT bump `tagsVersion` (a note has no grid surface). Rides the iCloud sidecar (`Sidecar.note`) + backup/restore (`BackupOccurrence.note`).
```

- [ ] **Step 2: Add a session-log entry**

Append a dated entry to `docs/session-log.md` summarizing the feature, the per-location decision, the LIKE-not-FTS decision, and the non-nil-beats-nil merge rationale. Reference the spec + this plan.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/session-log.md
git commit -m "docs: record per-file Note durable constraints + session log"
```

---

## Self-Review

**Spec coverage:**
- §1 storage (notes table, per-location) → Task 1. ✅
- §2 write seam (`TagStore.setNote`, no `tagsVersion` bump) + read → Task 2. ✅
- §3 UI (Note card, collapse default, copy button, save timing, localization) → Task 3. ✅
- §4 search (LIKE merge, not FTS, scope-respected) → Task 4 (+ NoteStore.searchIDs tested in Task 1). ✅
- §5 sidecar (field, build, non-nil-beats-nil merge, write, hydrate) → Task 5. ✅
- §6 backup/restore (BackupOccurrence.note, builder, applier) → Task 6. ✅
- §7 durable constraints recorded → Task 7. ✅
- Localization rule → Task 3 Step 5. ✅

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every test step shows the assertion.

**Type consistency:** `NoteStore.read/write/searchIDs` signatures identical across Tasks 1/2/5/6. `Sidecar.build` gains `note: String? = nil` (Task 5) — the pre-existing labeled call in `BackupBuilder` (`tags: [], updatedAt:`) still compiles unchanged (meta carries no note; note rides the occurrence). `note` added as the LAST, defaulted field of both `Sidecar` and `BackupOccurrence`, so existing positional initializers in `ReconnectApplierTests` compile; the `archive()` occurrence is updated in Task 6 Step 1 to pass `note:`. `ViewerFileDetails(...)` gains a required `note:` param — Task 2 Step 6 builds the whole app to catch any other call site.

**Ambiguity check:** Save timing is fully specified (blur / collapse / file-switch-flushes-old / disappear, compared against `loadedNote`). The `notes.updated_at` column is written from `now` on edit, from `sidecar.updated_at` on hydrate, and from `now` on restore — it feeds only the sidecar's whole-record LWW, so exact provenance doesn't affect correctness.
