# Hero viewer — per-file Note section

**Date:** 2026-07-07
**Status:** Design approved, pending spec review
**Scope:** Add a user-editable free-text "Note" to the hero image viewer's info column. Per file-location (like tags/ratings), searchable, synced via iCloud sidecars, carried through library backup/restore.

## Summary

The hero image viewer's right-rail info column gets a new **Note card**, sitting between the Rating card and the Colors card. It holds one free-text note the user types. The note is:

- **Per `(file_id, parent_dir)`** — same identity model as tags/ratings. The same image copied into another folder has its own note; deleting a note never leaks across folders.
- **Collapsible** — default **collapsed when empty, expanded when it has text**, re-evaluated each time a new image opens.
- **Copyable** — a copy button on the card puts the note text on the clipboard.
- **Searchable** — typing a word from a note surfaces that image, via the same `LIKE`-merge path tags already use (NOT via FTS — see §4).
- **Synced** — rides the iCloud sidecar and survives library backup/restore, exactly parallel to tags.
- **Localized** — every new user-facing string is wrapped for French.

Notes have **no grid surface** — they appear only in the hero viewer and in search results. There is no badge/glyph on grid tiles.

## Non-goals

- No note badge/indicator on grid tiles or search-result tiles.
- No rich text, no markdown, no length limit beyond a sane sanity cap.
- No note on the Collections page or hero collection pills.
- No FTS table rebuild.

---

## 1. Storage — `notes` table (per file-location)

`files.content_hash` is `UNIQUE`, so `files.id ↔ content_hash` is 1:1 — a per-`(file_id, parent_dir)` note **cannot** be a column on `files` (one file in two folders could carry two different notes). It gets its own table, modeled on the `tags` table's `(file_id, parent_dir)` scoping.

**New migration `v11_file_note`** in `Database.swift`, appended after `v10_collection_appearance` (~line 338):

```sql
CREATE TABLE notes (
    file_id    TEXT NOT NULL,
    parent_dir TEXT NOT NULL,
    body       TEXT NOT NULL,
    updated_at INTEGER NOT NULL,          -- epoch secs; drives sidecar LWW
    PRIMARY KEY (file_id, parent_dir),
    FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
)
```

- `PRIMARY KEY (file_id, parent_dir)` — exactly one note per location; upsert semantics.
- `ON DELETE CASCADE` — a file row deletion drops its notes automatically (parallels the tags FK).
- Empty/whitespace-only body = **row deleted**, not an empty-string row. "No note" is the absence of a row.

**New record `NoteRow`** in `Records.swift`, modeled on `TagRow`:

```swift
struct NoteRow: Codable, FetchableRecord, MutablePersistableRecord {
    var file_id: String
    var parent_dir: String
    var body: String
    var updated_at: Int64
    enum Columns { /* file_id, parent_dir, body, updated_at */ }
}
```

---

## 2. Write & read seam — `TagStore.setNote` + `ViewerFileDetails`

### Write

New method on `TagStore` (the existing per-`(file_id, parent_dir)` mutation hub), modeled on `setRating(_:forURLs:)`:

```swift
func setNote(_ body: String, forURL url: URL) async
```

- Resolves `url → (file_id, parent_dir)` via `TagScope.parentDir(of:)` + the alive-path lookup (same as `setRating`).
- Trims the body. If empty → `DELETE FROM notes WHERE file_id=? AND parent_dir=?`. Else → upsert the row with `updated_at = now`.
- On success, calls `AnalyzePipeline.shared.exportSidecarsAfterTagEdit(for: [url])` — the generic "a per-location field changed, re-push the sidecar (mergeExisting: false)" entry point that every manual tag/rating edit already uses.
- **Does NOT bump `appState.tagsVersion`.** A note has no grid surface, so re-evaluating grid chips/counts would be wasted work. (This is the one deliberate departure from the tag/rating write pattern — noted so a future reader doesn't mistake it for an omission.)

### Read

`ViewerFileDetails.load(queue:path:)` gains one query: fetch the note for `(fileID, parent_dir)` and populate a new `var note: String` (default `""`) on `ViewerFileDetails`. Reuses the `fileID`/scope it already resolves for tags.

---

## 3. UI — the Note card

**File:** `Views/Viewer/ViewerInfoColumn.swift`.

Insert a new `noteCard` computed property into the `body` VStack (~line 65), **between `ratingCard` and the colors card**. Built from the existing shell components:

- Wrapped in `InfoCard` (the shared radius-14 / `.white.opacity(0.09)` card shell).
- Header row: `CardLabel("Note")` on the left; a **copy button** on the right; a `PlusCircleButton` collapse toggle. (Match the header layout the `infoCard` collapse pattern already uses.)
- Body (when expanded): a multi-line `TextField("Add a note…", text: $draft, axis: .vertical)`, plainly styled to match `CardExpander`, min ~2 lines, grows with content, with a sane max height (scrolls past it).

**Collapse behavior:**

- `@State noteExpanded: Bool`. On file open / details load, set `noteExpanded = !note.isEmpty` (expanded iff there's text). The user can freely toggle while viewing.
- Collapsing commits any pending edit first (see save timing).

**Copy button:**

- SF Symbol `doc.on.doc` (or the app's existing copy glyph). `accessibilityLabel("Copy note")`.
- Copies the current note text to `NSPasteboard.general` (clear + `setString`).
- **Disabled** when the note is empty. Give brief affordance feedback (e.g. a momentary checkmark swap) consistent with any existing copy affordance; if none exists, a simple disabled↔enabled state is enough for v1.

**Editing / save timing.** Draft text lives in local `@State draft` (never bound straight to `AppState` — per the "never bind a TextField to `@Published` AppState" rule). Commit `draft` via `TagStore.setNote` when **any** of these happen, and only if `draft` actually changed vs. the loaded value:

1. The TextField loses focus (`@FocusState` `onChange`).
2. The card is collapsed.
3. The viewer's current file changes or the viewer closes (`onChange(of: currentURL)` / `onDisappear`).

Seed `draft` from `details.note` when the file changes (key on `currentURL`, like the folder-name-alert seeding pattern). This avoids per-keystroke DB writes.

**Localization.** New strings — `"Note"`, `"Add a note…"`, `"Copy note"` — wrapped in `String(localized:)` / SwiftUI text-literal positions so `-exportLocalizations` extracts them; fill the French values in `Localizable.xcstrings`.

---

## 4. Search — `LIKE` merge, not FTS

`files_fts` is keyed by the immutable `files.id` (per-content), so it **cannot** represent a per-`(file_id, parent_dir)` note. Notes are therefore matched the exact way tags already are: a `LIKE` query merged into the result set. **No FTS table rebuild; the three FTS population sites are untouched.**

In `SearchService.search(query:scope:)`, alongside the existing tag `LIKE` block (~lines 45–54), add a parallel notes match:

```sql
SELECT file_id FROM notes
WHERE parent_dir-scope-matches AND body LIKE ? ESCAPE '\'
```

- Reuse `ftsEscape` / the same `%…%` wrapping the tag path uses.
- Apply the **same `parent_dir` scope filtering** the tag match applies (respect All-folders vs. This-folder scope), so a note match only surfaces the file in a folder whose note actually matched.
- Merge the resulting `file_id`s into the same `exactIDs` set the tag matches feed. A file matches the query if its basename/caption/OCR (FTS) **or** any tag (LIKE) **or** its note (LIKE) matches.

Behavioral note: like tags, notes give a substring match rather than porter-stemmed token match. This is the correct and expected behavior for short user-authored free text, and matches how tag search already behaves.

---

## 5. iCloud sidecar sync

**Format** (`Sidecar.swift`): add `var note: String?` to the `Sidecar` struct (~line 42). Optional so pre-note sidecars decode to `nil` (same pattern as `BackupCollection.icon`/`color`). A sidecar already lives in exactly one folder's `.muse/`, so a top-level `note` on `Sidecar` is already per-`(file_id, parent_dir)`.

**Build** (`Sidecar.build(from:tags:updatedAt:)`): extend the signature to also take the note (read from the `notes` table in the same read that fetches tags), and stamp it onto the built sidecar. `Sidecar.apply(onto: &FileRow)` is **not** touched — the note is per-location, not a `FileRow` column.

**Write path** (`AnalyzePipeline.writeSidecarIfICloud`): in the existing `queue.read` block that fetches `(FileRow, [TagRow])`, also fetch the note for `(fileID, dir)` and pass it into `Sidecar.build(...)`. Everything downstream (merge, disk write) then carries it. `exportSidecarsAfterTagEdit(for:)` is called by `setNote` (§2) — the same manual-edit re-export tags use.

**Merge** (`Sidecar.merge(_ a, _ b)`, ~line 111): the note is a scalar with no union semantics, but plain last-writer-wins would let a newer analyze-export from a device that never hydrated the note **clobber** a real note with `nil`. So add an explicit rule after the winner is chosen:

```swift
// b = the fresh, DB-derived sidecar (call site: merge(existing, sidecar)).
// A non-nil note must never be overwritten by nil; between two non-nil, fresh wins.
winner.note = b.note ?? a.note
```

Genuine note **deletions** still propagate — they travel through the manual-edit path (`mergeExisting: false`), which overwrites the on-disk sidecar wholesale with current DB state (a `nil` note), bypassing merge. Merge only runs on the analyze path, where the note isn't being edited.

**Hydrate** (`SidecarHydrator.apply`): inside the existing `queue.write`, after the tag-upsert loop, upsert `sidecar.note` into the `notes` table keyed by `(fileID, parentDir)` (delete the row if `nil`/empty). The FTS mirror block is left alone (notes aren't in FTS).

**Inherited limitation (document, don't fix):** `SidecarHydrator` is gated on `analyzed_hash` — it only fires for files not yet analyzed at the current hash. A note edited on an already-analyzed file therefore propagates to another device through the same channels tags do, with the same gate. Notes inherit tags' sync guarantees exactly, including this pre-existing gate. Not a new defect; do not special-case it.

---

## 6. Library backup / restore

Per-location tags/ratings ride on `BackupOccurrence` (per `parent_dir`), **not** on `BackupFile.meta` (whose `tags` stays empty). The note follows the same rule.

**Model** (`BackupArchive.swift`): add `var note: String?` to `BackupOccurrence` (~line 22), Optional so old archives decode to `nil`.

**Build** (`BackupBuilder.swift`): alongside the existing `tagsByFileDir` map (built in the `queue.read`), build a `noteByFileDir` map from the `notes` table, and set `note:` on each `BackupOccurrence` (~lines 59–64). `meta` continues to be built with empty tags and no note.

**Restore** (`ReconnectApplier.applyMeta`): inside the existing `queue.write`, after the tag-upsert loop, upsert `m.occurrence.note` into the `notes` table keyed by `(fid, parentDir)` — `parentDir` is already computed there. (No FTS change.)

---

## 7. Tests

Pure/unit coverage (the app has no UI unit tests — the card itself is verified by running the app):

- **`SidecarTests.swift`**
  - JSON round-trip incl. a non-nil `note` (extend `testJSONRoundTrip`).
  - Old sidecar (no `note` key) decodes with `note == nil`.
  - **Merge rule:** `merge(existing-with-note, fresh-with-nil-note).note == existing note` (the clobber-guard); `merge(a-note, b-note).note == b note` (fresh wins between two non-nil). Extend `testMergeScalarsTakeNewer` / the `make(...)` helper to seed a note.
  - `Sidecar.build` carries the note (if signature changes, update `testBuildFromFileRowAndTags`).
- **`BackupArchiveTests.swift`** — `BackupOccurrence.note` round-trip; old archive decodes with `nil` note.
- **`ReconnectApplierTests.swift`** — a restored `occurrence.note` lands in the `notes` table at the new `parent_dir` (mirror the manual-beats-vision tag assertions).
- **New `NoteStore`/`setNote` behavior** (or fold into a `TagStore` test): empty body deletes the row; upsert replaces; scope isolation (same file, two `parent_dir`s → independent notes).
- **`SearchService` note match** — a note-only substring hit returns the file id; scope filtering respected (This-folder vs. All-folders); an empty note never matches.
- Migration `v11_file_note` applies cleanly on an existing library (schema test).

**Verification in the running app** (not just green tests — per the "verify runtime, not just tests" rule): open an image, add a note (card auto-expands with text on reopen), collapse/expand, copy, search for a word in the note and confirm the image surfaces, reopen a duplicate of the same file in another folder and confirm its note is independent.

---

## Durable constraints touched / to record on merge

- Add a `CLAUDE.md` durable note: **the note is per `(file_id, parent_dir)` like tags** (never a `files`/content-hash column — the UNIQUE content_hash makes that wrong), **searched via `LIKE` not FTS**, and its sidecar merge uses the **non-nil-beats-nil** clobber-guard (plain LWW would let an un-hydrated device erase a note).
- `setNote` deliberately does **not** bump `tagsVersion` (no grid surface).
