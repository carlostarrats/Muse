# Import Keywords & Ratings from Files (Lightroom / Bridge / Capture One)

**Date:** 2026-07-07 · **Status:** approved · **Branch:** feat/next-125

## What & why

Photographers coming from Adobe Bridge, Lightroom Classic, or Capture One have
years of keywords and star ratings written into their image files (embedded
IPTC/XMP, or `.xmp` sidecars beside RAWs). Muse currently reads none of it —
`FileMetadata` reads only EXIF/TIFF/GPS for the info card — so those users
start from zero. This feature reads that existing metadata and turns it into
Muse manual tags and star ratings. **Read-only: Muse never writes metadata into
files** (XMP *export* was investigated and rejected 2026-06-27; this feature
does not reopen it).

Demand exists now for this half; the sibling Eagle-library import was designed
but deliberately deferred — see `docs/future-features/eagle-library-import.md`.
Out of scope forever (no viable path): importing Instagram/X bookmarks
(exports contain links, never other people's media).

## UX

- **Menu:** File > **Import Keywords & Ratings…** placed in the existing
  `CommandGroup(after: .newItem)` in `MuseApp.swift`. A single item for now —
  when the Eagle import ever lands, both move under a File > Import submenu.
- **Panel:** folder-only `NSOpenPanel`, message: "Select a folder of images —
  keywords and ratings written by Lightroom, Bridge, or Capture One will be
  imported as Muse tags and ratings." Prompt: "Import".
- **Folder not in Muse yet:** it's added as a sidebar root first (the standard
  `BookmarkStore.addRoot` flow — activate-before-append rule applies), then
  imported. A folder already under an existing root is used as-is. Containment
  uses the `== prefix || hasPrefix(prefix + "/")` rule.
- **Progress:** a small sheet — count progress ("Reading 63 of 214…") +
  Cancel. Content-sized (no fixed height, so the `.windowFittedSheetHeight`
  rule isn't triggered). Cancel stops cleanly; work already applied stays
  (the operation is idempotent, so re-running finishes the rest).
- **Summary:** end state shown in the same sheet: "Imported keywords/ratings
  for N files · M had none · K skipped (unreadable)". Dismiss button.
- All new strings localized (French) per the localization rules; icon-only
  buttons get accessibility labels.

## What gets read, per file

Scope: files whose `AssetKind` is `.image` / `.raw` / `.psd`, enumerated
recursively under the chosen folder. Videos/PDFs/etc. are out (no demand;
keeps it simple).

Per file, in priority order (first source that yields a value wins per field):

1. **`.xmp` sidecar** beside the file (`IMG_1234.xmp` next to `IMG_1234.cr2`,
   case-insensitive extension match) — this is how Lightroom/Capture One
   handle RAW. Parsed with `CGImageMetadataCreateFromXMPData` (ImageIO parses
   the XMP packet; no hand-rolled XML).
2. **Embedded XMP** via `CGImageSourceCopyMetadataAtIndex` (no pixel decode).
3. **Embedded IPTC** via `CGImageSourceCopyPropertiesAtIndex` (header-only) —
   `kCGImagePropertyIPTCKeywords` / `kCGImagePropertyIPTCStarRating` — the
   legacy fallback for files written by older tools.

Fields extracted:

- **Keywords** — XMP `dc:subject` array, else IPTC Keywords. Flat keywords
  only; Lightroom's `lr:hierarchicalSubject` ("Travel|Japan|Tokyo") is NOT
  parsed — its leaf terms already appear in `dc:subject`. Trimmed,
  deduplicated case-insensitively, empty strings dropped. Stored **verbatim**
  as the canonical label (same as a hand-typed tag; no `VisionVocabulary`
  row — these are user words, not Vision labels).
- **Rating** — XMP `xmp:Rating`, else IPTC star rating. Clamped to 1–5;
  0/absent = no rating. (Lightroom's −1 "rejected" flag = no rating.)

**Dataless iCloud guard (constraint):** a not-downloaded iCloud file is
skipped (counted under "skipped"), same `.ubiquitousItemDownloadingStatusKey`
check as `AssetKind`/`FileMetadata` — reading metadata would force a download.
No pixel raster is ever decoded, so the 300 MP decode budget isn't in play.

## How it's written (conflict rules)

Sequencing: **index first, then apply.** Tags attach to `(file_id,
parent_dir)` rows, so files must be indexed before writes land (the
`addManualTag` path silently no-ops on unknown paths). The import explicitly
indexes the chosen folder recursively before applying metadata — the plan
picks the exact seam (the `Indexer` reconcile machinery; the App Intents'
`analyzableURLs(at:)` enumeration is the precedent for walking a folder
directly rather than reading `currentFiles`).

- **Keywords → manual tags** via a new batched `TagStore` write (one DB write
  + one sidecar re-export per file, not per keyword — `addManualTag` in a loop
  would export N times per file). Manual tier because these are human-made;
  manual-beats-vision protects them from the auto-tagger. Merging with an
  existing identical label is a no-op (insert-or-promote-to-manual, same
  branch `addManualTag` uses).
- **Rating → `TagStore.setRating` only if the file has no Muse rating.**
  `setRating` itself overwrites (mutual exclusion), so the import reads the
  existing rating first and skips rated files — a rating the user set in Muse
  is never clobbered by an import.
- **Idempotent by construction:** tags merge, ratings only fill gaps. Running
  twice changes nothing the second time.
- Per-file read failures (corrupt file, unreadable metadata) skip + count;
  they never abort the run.
- iCloud-zone files get their sidecars re-exported by the existing TagStore
  seams (comes free).

## Components (new code lives in `Muse/Muse/Import/`)

| Unit | Purpose | Testable how |
|---|---|---|
| `MetadataKeywordReader` | URL → `(keywords: [String], rating: Int?)`; sidecar/embedded-XMP/IPTC priority; dataless guard | Unit tests against fixture images + fixture `.xmp` packets |
| `ImportPlan` (pure) | Merge rules: keyword trim/dedupe, rating clamp, only-if-none decision given existing state | Pure unit tests |
| `MetadataImporter` (@MainActor service) | Panel → root-add-if-needed → enumerate → index → read (off-main) → batched writes → progress/cancel/summary state | Integration test on a temp DB + temp folder for the write path |
| `ImportProgressSheet` (View) | Progress/summary/cancel UI | Not unit-tested (consistent with other views) |
| `TagStore.addManualTags(labels:for:)` | Batched manual-tag write seam | Extends existing `TagStoreTests` |

Menu item in `MuseApp.swift`; strings in `Localizable.xcstrings`.

## Info modal (`Views/InfoSheet.swift`)

- Add a line: Muse imports keywords & star ratings written by Lightroom,
  Bridge, and Capture One (File > Import Keywords & Ratings…).
- While in there, fix the stale privacy line: it predates the Drive share.
  It must say the only network activity is update checks **plus the opt-in
  Google Drive share you trigger yourself**, which uploads only to *your own*
  Drive under the `drive.file` scope (Muse can only touch files it created);
  the developer receives no data either way.

## Testing

- Fixture-driven unit tests: tiny JPEGs with known embedded IPTC/XMP (written
  once via ImageIO in a test helper), fixture `.xmp` sidecar strings covering
  Lightroom and Capture One shapes, hierarchical-subject files (leafs come
  through `dc:subject`), rating clamp edges (0, −1, 6), keyword dedupe/trim.
- `ImportPlan` conflict-rule tests: existing-rating-skip, tag merge, idempotency.
- Integration: temp DB + temp folder → index → import → assert tags/ratings;
  re-run → assert unchanged.
- Suite runs in an English host per the localization convention.

## Explicitly out / rejected

- Writing metadata back into files (rejected 2026-06-27; never-modify-originals).
- Eagle import (deferred — `docs/future-features/eagle-library-import.md`).
- Instagram/X bookmark import (no viable, legal, network-free path).
- Hierarchical keyword trees, color labels, GPS-to-tag, caption import — YAGNI
  for now; keywords + stars are the demanded core.
