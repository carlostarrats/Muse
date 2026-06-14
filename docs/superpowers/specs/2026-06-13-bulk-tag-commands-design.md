# Bulk tag commands — Delete All Tags + Regenerate Tags

**Date:** 2026-06-13
**Status:** Approved, ready for implementation plan
**Scope:** Two new menu-bar commands in the Tags menu, both
current-folder scoped.

## Problem

Tags can only be removed one at a time from the hero image viewer. If a
user wants to clear the tags on a folder and start over — or doesn't
like the auto-generated tags — there's no bulk escape hatch. And once
vision tags are deleted, the automatic pipeline never regenerates them
(it's gated on `analyzed_hash == content_hash`, so it thinks every image
is already done), so there's also no way back.

This adds two commands that cover both directions, scoped to the folder
the user is currently looking at.

## Scope decisions (locked)

- **Both commands operate on the current folder only**, not the whole
  library. "Current folder" = the files in `AppState.currentFiles`
  (the active sidebar folder's enumerated files). Not collection- or
  search-filtered — the raw folder contents.
- **Delete All Tags removes both kinds of tags** — auto-generated
  (vision) *and* manual (user-typed). Manual tags cannot be recovered;
  the confirmation modal says so.
- **Regenerate only restores vision tags** (it re-runs the Vision
  pipeline). Manual tags are not restored — by design.
- **Collections are out of scope.** An earlier idea for a "Delete All
  Collections" command was dropped: collections are cheap to delete
  individually and are recomputed by the clustering engine anyway.

## Design

### Command 1 — Delete All Tags… (this folder)

Removes every tag row for the current folder's files.

- **DB op:** delete all `tags` rows whose `file_id` belongs to a
  current-folder file. Resolve current-folder file IDs from
  `AppState.currentFiles` URLs via the `paths` table (alive paths),
  mirroring the resolution already done in `AnalyzePipeline.analyze`.
- **Deliberately does NOT touch `analyzed_hash`.** This is the crux of
  the design: the automatic analysis pipeline is gated on
  `analyzed_hash`. Leaving it untouched means deleted tags **stay
  deleted** — they will not silently reappear when the user revisits the
  folder or the next index pass runs. They only come back when the user
  explicitly runs Regenerate.
- **No FTS cleanup needed.** Tags are not stored in the FTS index
  (`files_fts` holds basename/ocr_text/caption only). Tag search is a
  separate `TagRow.label LIKE` lookup in `SearchService`, which naturally
  returns nothing once the rows are gone. Verified against
  `AnalyzePipeline.swift:227–230` and `SearchService.swift:38–40`.
- **UI after delete:** clear the active tag filter
  (`setActiveTag(nil)`) and bump `tagsVersion` so `TagChipsRow` reloads
  (now empty for this folder).
- **Confirmation modal** (folder-scoped wording):
  - Title: `Delete all tags in this folder?`
  - Body: *"This removes every tag on the images in this folder — both
    automatic tags and ones you've added yourself. Tags you added by
    hand can't be recovered."*
  - Buttons: Cancel (default) · **Delete All** (destructive).

### Command 2 — Regenerate Tags… (this folder)

Re-runs analysis on current-folder images **that currently have zero
tags**, regenerating their vision tags (and the rest of the per-file
analysis: caption, dominant color, palette, FTS, screenshot intent).

- **Gate = "files with no tags."** This is what makes it both the
  recovery path and incremental:
  - After a Delete All, every file in the folder has zero tags → all are
    regenerated.
  - In normal use, files that already have tags are skipped → it never
    redoes finished work; it only fills gaps (new/untagged images).
  - This satisfies the edge case directly: a fully-tagged folder
    regenerates nothing.
- **Why the gate is "no tags" rather than resetting `analyzed_hash`:**
  resetting `analyzed_hash` would make the *automatic* pipeline resurrect
  tags on the next folder visit (defeating Delete All's permanence). The
  no-tags gate is decoupled from `analyzed_hash`, so the two commands
  don't interfere. Regenerate is the *only* code path that uses this
  gate; it runs only on explicit user action.
- **DB op / pipeline:** add a folder-scoped method to `AnalyzePipeline`
  (e.g. `regenerateTagless(in urls:)`) that:
  1. Resolves the current-folder URLs to file IDs (as
     `analyze(folder:)` does).
  2. Filters to file IDs with no rows in `tags` (a
     `LEFT JOIN tags ... WHERE tags.id IS NULL`, or `NOT EXISTS`).
  3. Calls the existing `analyze(folder:)` on just those URLs — reusing
     the existing per-file analysis, progress (`completed`/`total`),
     pill, and `CollectionsEngine.recluster()` at the end.
- **Progress:** uses the existing bottom-center "Analyzing N of M" pill
  driven by `AnalyzePipeline.completed`/`total`/`isRunning`. Runs in the
  background; the menu command just kicks it off.
- **Light confirmation modal** (it's background work, not destructive,
  but worth a beat):
  - Title: `Regenerate tags for this folder?`
  - Body: *"Looks for images in this folder that have no tags and
    generates tags for them in the background. Images that already have
    tags are left alone. Only automatic tags are created — tags you
    added by hand aren't restored."*
  - Buttons: Cancel (default) · **Regenerate**.

### Known minor (accepted)

An image where Vision legitimately produced **no** tags (e.g. a
plain-color screenshot) has zero tags, so Regenerate will re-run it each
time it's clicked. This is harmless — it only redoes that one file, only
on an explicit click, never automatically — and keeps the model simple.
Tracking "analyzed but tagless" separately to skip these was considered
and rejected as not worth the complexity.

## Wiring (follows existing patterns)

- **`MuseApp.swift`** — add two `Button`s to the existing
  `CommandMenu("Tags")`, under a `Divider()` below the current
  Rename/Delete/Clear items. Both set request flags on `AppState`. Both
  enabled only when a folder is selected and has files
  (`!appState.currentFiles.isEmpty`); not gated on a selected tag.
- **`AppState.swift`** — add two `@Published` request flags following the
  existing `tagDeleteRequest`/`collectionDeleteRequest` shape:
  - `@Published var deleteAllTagsRequest = false`
  - `@Published var regenerateTagsRequest = false`
- **`TagChipsRow.swift`** — consume both flags with `.alert(...)` +
  `Binding`, exactly like the existing Rename/Delete Tag alerts. On
  confirm:
  - Delete All → `TagStore.shared.deleteAllTags(forURLs:)` (new), then
    `setActiveTag(nil)` + `tagsVersion += 1`.
  - Regenerate → `AnalyzePipeline.shared.regenerateTagless(in:)` (new) in
    a `Task`, then `tagsVersion += 1` on completion.
- **`TagStore.swift`** — add `deleteAllTags(forURLs urls: [URL])`:
  resolve URLs → file IDs via alive paths, `DELETE FROM tags WHERE
  file_id IN (...)`. Does not touch `files`/`analyzed_hash`.
- **`AnalyzePipeline.swift`** — add `regenerateTagless(in urls: [URL])`
  as described above.

No new screens, no schema migration, no FTS changes.

## Out of scope / non-goals

- Library-wide variants (current-folder only, per the locked decision).
- Any "Delete All Collections" command (dropped).
- Restoring manual tags after deletion (impossible by design — they
  aren't derivable).
- A separate "analyzed but tagless" marker (rejected; see Known minor).

## Files touched

- `Muse/Muse/MuseApp.swift` — two menu buttons.
- `Muse/Muse/Models/AppState.swift` — two request flags.
- `Muse/Muse/Views/TagChipsRow.swift` — two confirmation alerts + handlers.
- `Muse/Muse/Database/TagStore.swift` — `deleteAllTags(forURLs:)`.
- `Muse/Muse/Intelligence/AnalyzePipeline.swift` — `regenerateTagless(in:)`.
