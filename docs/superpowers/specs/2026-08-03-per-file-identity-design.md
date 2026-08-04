# Per-file identity — design

**Date:** 2026-08-03
**Status:** design, approved in conversation, not yet planned or built
**Owner decision:** Option B — "every image should be its own. own editing, own
tags, own everything. even duplicates. even images with the same bytes."

---

## 1. The bug this exists to kill

Twelve byte-identical `.ARW` files in one folder:

```
/Users/…/Desktop/Raw Files/RAW_SONY_ILCA-77M2.ARW
/Users/…/Desktop/Raw Files/RAW_SONY_ILCA-77M2 copy.ARW
…
/Users/…/Desktop/Raw Files/RAW_SONY_ILCA-77M2 copy 2 2 2.ARW
```

Edit one and all twelve change. Confirmed against the live database: one `files`
row, twelve alive `paths` rows, one `edits` row.

**Root cause.** `files.content_hash` is `UNIQUE` (`Database.swift:94`), so
identical bytes collapse to one row. Per-location user data is keyed
`(file_id, parent_dir)` — the tags/notes/edits grain. Twelve copies in the *same*
folder share **both halves** of that key, so they share one edit stack.

The code anticipated the neighbouring case and guards it — but only across
folders (`EditRecordStore.allWithAlivePaths`):

```swift
// A file can be alive at several paths; the edit belongs to the
// one in ITS folder. Without this filter a stack applied to the
// copy in /A would render the untouched copy in /B too.
guard TagScope.parentDir(ofPath: path) == dir else { return nil }
```

Same-folder copies pass that filter unchanged.

**It is not edits-only and not RAW-only.** The same grain pools tags, star
ratings and notes across same-folder copies, and collection membership is keyed
on `file_id` alone — so adding one copy to a collection adds all twelve,
in *any* folder. Filename search is worse: `files_fts` holds one row per
`files` row with one `basename`, so eleven of the twelve names are unfindable.

**Owner's motivating workflow:** duplicate a photo deliberately, edit each copy
differently, compare. Today that is impossible.

---

## 2. The model

**A file on disk is the unit of identity.** Content is still compared behind the
scenes — that is how Find Duplicates works and how identical pixels avoid being
analyzed twelve times — but it is no longer *identity*.

### 2.1 What becomes per-file

| Data | Today | After |
|---|---|---|
| `edits` | `(file_id, parent_dir)` | `file_id` |
| `edit_versions` | `(file_id, parent_dir)` | `file_id` |
| `tags` (incl. star ratings) | `(file_id, parent_dir, label)` | `(file_id, label)` |
| `notes` | `(file_id, parent_dir)` | `file_id` |
| `collection_members` | `file_id` — **no schema change needed** | correct by construction |
| `collection_exclusions` | `file_id` — **no schema change needed** | correct by construction |
| `files_fts.basename` | `file_id` — **no schema change needed** | correct by construction |

Half the tables need no migration at all. They become correct because `file_id`
finally means "this file", not "these bytes". That is the argument for Option B
over patching six tables: correctness stops depending on every future query
remembering to add a folder filter.

**`parent_dir` is dropped, not retained.** Once `file_id` identifies a file it
also identifies the folder, so the column is redundant — and a redundant key
column is exactly what let this bug through. `TagScope.parentDir` and its call
sites go with it.

### 2.2 What stays shared, invisibly

Everything derived from the pixels is identical for identical bytes and
expensive to compute:

`photo_meta` (EXIF), `photo_traits` (faces, sharpness, clipping), `places`
(GPS → city), `embeddings`, `clip_embeddings`, and on `files` itself:
`caption`, `dominant_color`, palette, `width`/`height`, `feature_print`, plus
OCR text in FTS.

These become **per-file rows carrying a copy of a per-content result**. Each file
owns its row; the *value* is computed once per distinct `content_hash` and
copied. The user never sees the difference. Without this rule, twelve identical
RAWs cost twelve Vision passes.

### 2.3 Schema shape

- `files.content_hash` loses `UNIQUE`, keeps a (now non-unique) index. It becomes
  a grouping key.
- **Invariant: a `files` row has at most one alive path.** Dead paths may still
  point at it (that is how a re-appearing file is revived). This replaces
  `content_hash UNIQUE` as the structural guarantee and must be asserted in
  tests, since nothing in SQLite enforces it.
- `paths` is otherwise unchanged — it still owns `absolute_path`, `is_alive` and
  `bookmark_data`. It is not merged into `files`; the dead-path lifecycle is
  worth keeping separate.

---

## 3. New copies inherit

**Owner decision.** A new file whose bytes match an existing file arrives
carrying that file's edits, tags, note and collection memberships, then diverges.

Rationale: duplicating a photo to try a variation should start from where you
were, not from blank. The alternative (always blank) is more predictable but
makes "duplicate and try something else" a redo.

**Donor selection**, when several existing copies could be inherited from:

1. A copy in the **same folder**, if there is one.
2. Otherwise the **most recently edited** copy (`edits.updated_at`).
3. Tie-break on lowest `absolute_path`, so the rule is deterministic and
   testable.

This is "you duplicated the one you were just working on".

Inheritance is a **copy at creation time**, never a live link. Editing the
original afterwards does not touch the copy.

---

## 4. What this deletes

The change is a net simplification. All of the following exist only because a
`files` row can be shared, and all of them go:

- `Indexer.reconcile`'s **split-on-edit-in-place** branch (a shared row must
  split when one copy is edited).
- The **hash-collision** branch's two-way carry, with its
  `keepsSiblingInDir` reasoning.
- `unionTags(parentDir:deleteOriginals:)`'s scoping parameters.
- `NoteStore.carry` / `EditRecordStore.carry` folder parameters, and
  `EditRecordStore`'s two per-folder filters.
- `TagScope.parentDir` and every call site.

Edit-in-place becomes trivial: a file's bytes changed, so update *its*
`content_hash` and re-derive *its* analysis. Two rows sharing a hash is now
legal, so there is nothing to reconcile.

---

## 5. Migration (v24)

Migrations currently run through v23. This is v24, and it is pure SQL over rows —
no filesystem access, so no fail-closed root-reachability concern.

For each `files` row **F** with alive paths `P₁…Pₙ`, `n > 1`, ordered by
`absolute_path`:

1. Keep **F** for `P₁`.
2. For each `Pᵢ`, `i > 1`, insert a new `files` row **Fᵢ** copying every
   content-derived column, and copy the derived rows (`photo_meta`,
   `photo_traits`, `places`, `embeddings`, `clip_embeddings`) plus an FTS row
   carrying **`Pᵢ`'s own basename** — which is how eleven filenames become
   searchable.
3. Re-point `Pᵢ.file_id = Fᵢ`.
4. Per-location user data: the `(F, parent_dir(Pᵢ))` rows in `tags`, `notes`,
   `edits`, `edit_versions` move to `Fᵢ`, dropping `parent_dir`.
   **When several paths share one folder — the reported bug — each gets a
   *copy*.** That is §3's inherit rule applied to existing data: nothing the
   owner can currently see is lost, and the copies diverge from the next edit on.
5. `collection_members` and `collection_exclusions` rows for F are **copied** to
   every `Fᵢ`. All copies are members today; keep them members.
6. Dead paths stay on F.
7. `duplicate_members` / `stack_members` are derived caches — clear them; the
   next Find Duplicates run rebuilds.

Then drop the `UNIQUE` on `content_hash` (SQLite: rebuild the index).

**Cost.** Storage grows by the derived rows per extra copy — dominated by the
CLIP vector, on the order of a few KB per duplicate. Acceptable.

---

## 6. Three things that need re-checking

### 6.1 iCloud sidecars — a real collision

`SidecarStore.sidecarURL` writes `<folder>/.muse/<content_hash>.json`. Two
copies of the same bytes in one folder **collide on one sidecar file**, so
per-file data cannot round-trip through sync.

**Fix:** write `<content_hash>__<basename>.json`. Keep reading the old
`<content_hash>.json` name as a fallback, so libraries already synced keep
hydrating. A rename orphans a sidecar; sidecars are a regenerable sync artifact,
and housekeeping prunes `.muse` entries with no matching asset.

### 6.2 Backup — mostly already correct

`BackupOccurrence` already carries `tags`, `note`, `edit_stack` and
`edit_versions` **per occurrence**. Only membership is per-content:
`BackupMember.content_hash`, `cover_hash`, `excluded_hashes`.

**Fix:** carry membership per occurrence (path-keyed) as new optional fields,
leaving the existing per-hash fields readable. The archive's compatibility
mechanism is optional-fields-with-nil-default, not a schema bump
(`BackupArchive.currentSchema` stays 1) — follow it.

Restore matches archived files to disk by content hash; with several rows per
hash it must map **occurrence → path**, not hash → row.

### 6.3 Find Duplicates — no change

`DuplicateFinder.byteExactGroups` already reads `paths` and groups by
`content_hash`, so N rows per hash is its natural shape. `DuplicateDeleteRules`
(never delete a whole group) is unaffected. It gets *better*: each member now has
its own tags and edits, so the keeper choice means something.

`ThumbnailCache` is already keyed on `(url, size, scale, stackHash)` — per-file
already, no change.

---

## 7. Testing

Unit tests, all against an in-memory queue:

- **Migration:** n copies in one folder; n copies across folders; a mix; dead
  paths preserved; per-folder user data lands on the right row; same-folder
  copies each get their own copy of edits/tags/note; collection membership
  copied to all.
- **The invariant:** no `files` row ends with two alive paths — asserted after
  migration and after each indexer branch.
- **Inherit rule:** donor selection prefers same folder, then most recently
  edited, then lowest path; deterministic across orderings.
- **Analysis reuse:** indexing a copy of already-analyzed bytes performs **zero**
  Vision/CLIP work and still produces a fully-populated row.
- **Isolation — the reported bug:** two same-folder copies, edit one, assert the
  other's stack, tags, note and thumbnail key are untouched.
- **FTS:** each copy findable by its own basename.

`./scripts/audit-invariants.sh` must stay green; consider adding a check that
`parent_dir` no longer appears in the four re-keyed tables.

---

## 8. Deliberately not in scope

- Merging `paths` into `files`. They are 1:1 for alive rows now, but the dead-path
  lifecycle earns its own table. Tempting, unrelated.
- Any change to how duplicates are *presented*. The finder is untouched.
- Reviving near-duplicate stacks (`stacks` / `stack_members`), dropped
  2026-08-01. Those tables stay unused.
