# Future feature: Eagle library import

**Status: designed, deliberately deferred (2026-07-07).** Not built because no
current demand — the owner knows of no Eagle users today. The sibling feature
(Lightroom/Bridge/Capture One keywords + ratings import) shipped first because
demand exists now; see
`docs/superpowers/specs/2026-07-07-metadata-keywords-import-design.md`.
If Eagle demand ever appears, this design was brainstormed and approved — start
here, don't re-derive it.

## What it is

File > Import > **From Eagle Library…** — a one-time migration that rescues a
user's [Eagle](https://en.eagle.cool) library (a `.library` package of files +
JSON metadata) into a normal folder Muse watches, carrying tags, star ratings,
and folder groupings along.

## Why it fits Muse

- Reads Eagle read-only; writes only Muse's own DB; never modifies an image
  file. All the write-side machinery already exists (`TagStore.addManualTag`,
  `TagStore.setRating`, `CollectionStore.createManual`) — the feature is a
  reader/translator, not a new subsystem.
- It's a sanctioned exception to "Muse doesn't file-manage" in the same spirit
  as rename/move: a user-initiated, one-time act of organizing.

## Eagle's format (verify against a real library before building)

From training knowledge, unverified — **step 1 of any build is creating a
scratch library with the real Eagle app and confirming this:**

- A library is `<name>.library/images/<ID>.info/` folders, each holding the
  original file plus a per-item `metadata.json` (tags, star rating, annotation,
  URL, folder-membership IDs).
- A root `metadata.json` defines the folder tree (folders can nest).
- **Each image is stored exactly once.** Eagle folders are album-like labels —
  an image "in" three folders is one file shown in three places. This is the
  key fact that shaped the design below.

## Approved design (owner-approved 2026-07-07)

- **UX:** File > Import > From Eagle Library… → open panel restricted to
  `.library` packages (message: "Select your Eagle library (e.g. My
  Library.library)") → second panel picks a destination folder → progress sheet
  with cancel → end summary ("214 imported, 2 skipped").
- **Files:** each image copied **once**, flat into the destination (the
  destination is the pool, as Eagle's library was). No disk duplication.
- **Eagle folders → Muse collections** — a reflection, never copies. An image
  in three Eagle folders = one file, member of three collections. Nested Eagle
  folders flatten to "Parent – Child" collection names (Muse collections are
  flat).
- **Eagle tags → Muse manual tags** (manual tier: human-made, protected from
  the auto-tagger). **Eagle stars → Muse rating** via the one
  `TagStore.setRating` seam; never overwrites a rating already set in Muse.
- **Dropped:** Eagle notes/annotations/URLs (Muse has no field), smart folders
  (saved searches, not real groups), Eagle's own palette data (Muse computes
  its own).
- **Idempotent:** re-running the same import skips files already present at the
  destination instead of duplicating.
- **Sequencing:** copy → index the destination (files need `paths` rows before
  tags can attach) → apply tags/ratings/collections.
- Per-file copy failures skip + count, surfaced in the end summary. All new
  strings localized. Progress sheet obeys the `.windowFittedSheetHeight` rule
  if fixed-height.

## Explicitly rejected while designing

- **Recreating Eagle folders as disk folders with duplicated files** — Eagle
  never duplicates; collections are a presentation, not copies (owner call).
- **Social bookmark import (Instagram saved / X bookmarks)** — no viable path:
  data exports contain links, never other people's media; fetching would break
  the no-network identity and platform ToS. X exports likes (text+link only,
  no media) and omits bookmarks entirely.

## When building, share with the shipped metadata import

The Lightroom/Bridge import (shipped) established the ingestion seams this
feature should reuse: the batch manual-tag write, the rating-only-if-none rule,
the post-index metadata-apply sequencing, and the File > Import menu location
(promote the single item to a File > Import submenu when Eagle joins it).
