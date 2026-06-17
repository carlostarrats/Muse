# Per-file tags — design

**Date:** 2026-06-17
**Branch:** `feat/per-file-tags`
**Status:** approved, in implementation

## Problem

Muse identifies an image by its **content hash** (`files.id`, welded in
`Indexer.reconcile`). Two byte-identical files in two folders share one
`files` row, and tags hang off that shared id (`tags.file_id`). So:

- Editing/deleting a tag on one copy silently affects the duplicate in
  another folder (proven in the live DB: 12 welded identities, e.g. a
  flavicon screenshot at 3 paths sharing 7 tags).
- The right-click tag-chip **"Delete Tag"** calls `TagStore.deleteLabel`
  → `DELETE FROM tags WHERE label = ?` — removes the label from **every
  image in the entire library**, regardless of folder.

The user's model: **a file lives in exactly one folder; a duplicate in
another folder is its own image with its own tags. Only collections are
cross-folder.** The content-hash welding violates this.

## Decision

**Tags become per-file-location.** Key tags by **(content identity,
parent folder)** = `(file_id, parent_dir)`, not by `file_id` alone.

Why parent-folder scope rather than per-path-id:

- **Rename-in-place preserves tags for free** — same content, same folder
  ⇒ same tag scope. No fragile rename detection in the indexer.
- **A duplicate in another folder is independent** — different folder ⇒
  different scope ⇒ its own tags. Deletes never leak across folders.
- **Edit-in-place resets tags** — a crop changes the content hash ⇒ new
  scope ⇒ tags regenerate (matches the existing 2026-06-17 edit-refresh).
- Matches the user's phrasing exactly: "this image, in this folder."

Accepted edge case: two **byte-identical** files in the **same** folder
with different names share tag scope. Rare (you'd normally dedupe them);
preserving rename was judged more valuable than splitting this case.

### Metadata stays content-keyed (deliberate, in scope)

Content-derived metadata (palette, caption, dimensions, intent,
feature_print, embeddings, FTS) stays keyed by `file_id`. For
byte-identical pixels these values are **mathematically identical** and
not user-editable, and they **auto-split** the moment one copy is edited
(its hash changes). Forcing separate rows would mean tearing down the
`content_hash UNIQUE` identity model (dedup, iCloud sidecar, FTS,
embeddings) for **zero observable difference**. The user confirmed
"its own metadata" means what is observable/editable — i.e. tags.

### No global delete

`TagStore.deleteLabel` (library-wide delete-by-label) is removed. The
tag-chip "Delete Tag" deletes only the current view's files
(folder/collection), via the same path-scoped delete as the other
tag-removal actions.

## Scope of change

- **Schema migration** — `tags` gains `parent_dir TEXT`; existing tags
  fan out across the distinct alive parent folders of each `file_id`
  (preserves everything currently visible); `UNIQUE(file_id, label)` →
  `UNIQUE(file_id, parent_dir, label)`.
- **TagStore** — `tags(for:)`, `addManualTag`, `removeTag`, `removeLabel`,
  `deleteAllTags` scope by `parent_dir` derived from the URL. New
  `TagScope.parentDir(of:)` helper. `deleteLabel` removed.
- **AnalyzePipeline** — writes vision tags for **each alive parent folder**
  of the file (manual-beats-vision enforced per scope).
- **Indexer.unionTags** — parent-dir-aware when an edit-in-place collides
  with another file row.
- **Sidecar / hydrator** — already per-folder; build/hydrate uses only
  that folder's tags.
- **TagChipsRow / SearchService** — aggregation + tag-label search verified
  under the new key.

## Safety / verification

- Live DB backed up before migration.
- Migration + scoping logic covered by tests (TDD).
- Before/after diff against the real DB: every previously-visible tag
  still resolves in its folder; welded duplicates are now independent.
- Debug build + `MuseTests` green.

## Out of scope

Splitting content-derived metadata per copy (the `content_hash`-UNIQUE
teardown). Can be added later if ever wanted; nothing here precludes it.
