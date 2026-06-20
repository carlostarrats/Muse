# Library Backup & Reconnect — design

**Date:** 2026-06-20
**Status:** Approved (brainstorm) — pending implementation plan

## Problem

A user spends months building up Muse: pointing it at folders, letting it
auto-tag and auto-collect, hand-typing tags, and curating collections. None of
that lives in the files themselves — it lives in Muse's local SQLite DB. When
the user buys a new Mac, they copy **their files** over and redownload Muse.
Muse starts blank. All collections, tags, stars, and AI metadata are gone, and
there is no path to get them back.

The existing iCloud sidecar mechanism (`.muse/<hash>.json` next to each image)
does carry most per-file metadata — **but we cannot rely on it for migration.**
Those folders are hidden; a normal "copy my photos to the new Mac" drops them,
and they carry no collections at all. The migration story must assume **nothing
survives except a file the user deliberately exported.**

## Goal

Two explicit, legible user actions:

1. **Back Up Muse…** — produce one self-contained file the user knowingly saves
   and carries to the new Mac.
2. **Restore from Backup…** — on the new Mac, load that file and **reconnect**
   its data to the user's files wherever they now live, through a guided,
   self-contained wizard.

## Non-goals

- No reliance on the hidden `.muse/` sidecars surviving a move (they may not).
- No cloud/account/network anything — Muse's only network path stays Sparkle.
- No "ghost" or placeholder entries ever appearing in the live library UI.
- Not a continuous/automatic backup. The user triggers it. (It *may* be used
  periodically — see Reconciliation — but it is never silent.)

## Load-bearing principles

1. **Explicit and self-contained.** The export is the only thing that travels.
   It contains everything needed; it relies on no hidden state. The export
   action teaches the next action ("keep this file; you'll restore from it").
2. **The live library never shows anything dead.** "Ghost" is a wizard-only
   concept. The real app only ever renders real, connected files. A collection
   that reconnects to zero files is **not created**; a collection where 1 of 12
   images reconnects opens showing **just that 1 image** — no placeholders, no
   broken tiles.
3. **Restore reconciles, it does not overwrite.** The backup seeds metadata onto
   every file it can match; then normal indexing sweeps the same folders, so any
   file on disk that is *not* in the backup (new or changed) is indexed and
   analyzed fresh through the existing pipeline. Backup fills in the known; the
   normal pipeline handles the new. Backup entries that never match never leak
   into the library.

## Identity & matching

Every file is recorded by **content fingerprint (SHA-256) + original filename +
original absolute path**. On the new Mac, reconnection matches a backup entry to
a real file by:

1. **Content fingerprint first** — byte-identical match. Reconnects even if the
   file was renamed or moved to a differently-named folder. This is exact and is
   the 95% path.
2. **Filename fallback** — when no fingerprint matches in the pointed-at
   location, a same-named file is offered as a *name-only* match (the file was
   re-saved/edited, so its bytes changed). Surfaced for review rather than
   silently accepted.

This reuses machinery already present: `HashService` computes the SHA-256 today
during indexing, and the new Mac re-hashes files as it indexes the
pointed-at folders anyway.

**Confidence tiers drive the UI:** exact fingerprint matches reconnect silently
(solid/✓); name-only matches land in a "review these" state for the user to
confirm or reject.

## What the export contains (Option 1 — "everything that makes Muse yours")

The export is essentially **the sidecar payload for every file, plus the things
sidecars cannot carry**, assembled into one explicit file:

- **Folder list** — the sidebar roots (so the wizard can show folder rows), each
  by original absolute path + display name.
- **Per-file identity index** — content hash, original filename, original
  absolute path, and which root it lived under.
- **Tags** — manual *and* AI, with `source` / `confidence` / `model_version`.
  Manual tags are the one irreplaceable thing (they cannot be re-derived), so
  they are always included.
- **AI-derived metadata** per file — caption, palette, dominant color, width/
  height, duration, intent, `analyzed_hash`, feature print — so the new Mac does
  **not** re-run Vision over the whole library.
- **Collections** — full state: name, `sort_order`, chosen cover, `model_version`
  (auto vs manual), hidden state, **members by content hash**, and exclusions.
- **Starred folders.**

**Excluded** (regenerable or heavy): thumbnails (rebuild on their own) and OCR
full-text (large; already excluded from sidecars today — the "degraded OCR on
hydrate-only devices" by-design note applies equally here).

The file is text-based (JSON), so it stays small even for large libraries (no
image bytes). Proposed extension/package: a single `.muselibrary` document
(e.g. `Muse Backup 2026-06-20.muselibrary`).

### Re-keying (the genuinely new data work)

- **Collection membership** is stored in SQLite by per-machine random UUID
  (`FileRow.id`), which is regenerated on every machine and is therefore **not
  portable**. On export, each member is rewritten from its UUID to its **content
  hash**. On import, each content hash is resolved back to the new Mac's UUID via
  fingerprint match. This is the core reason collections are lost today and the
  core fix.
- **Tags** are keyed `(file_id, parent_dir)` (per file *location*). On export
  they are stored against `(content_hash, original parent_dir)`. On reconnect
  they are re-applied at the matched file's **new** parent_dir — so a reorganized
  folder still gets its tags, scoped to where the file now lives.

## Export flow — "Back Up Muse…"

- Menu item in the **Muse** app menu: **"Back Up Muse…"**.
- Opens an `NSSavePanel` defaulting to a sensible name + Desktop.
- Plain guidance in/around the panel: *"This is your Muse backup. Keep it
  somewhere safe — ideally not only on this Mac. You'll use it to restore your
  collections, tags, and folders on another Mac."*
- Assembling the payload runs off the main actor (it reads the DB); the file is
  written atomically.

## Restore flow — the Reconnect wizard

- Menu item **"Restore from Backup…"** → file picker → the **locked wizard**
  opens. The backup loads into a **staging area, not the live library**, so
  ghosts never touch the real app.
- **Folder rows:** the backup's roots, one per row.
- **Pointing:** default is **point at one parent folder** once; the wizard
  auto-maps each original folder to a matching subfolder by name + content. Each
  row also has a **Locate…** button for anything that does not auto-map.
- **Reconnect All:** a single button queues every folder and runs the whole pass
  automatically — the user can walk away. Failures do not stop the queue.
- **Per-folder status:** working → **✓ clean** / **⚑ flagged** (some files
  unmatched). Within each folder, matching uses fingerprint-then-filename.
- **Collections readout:** alongside the folders, a read-only progress list —
  "42 / 60 re-established," partials show "3 of 12 images." A flagged or
  not-imported folder **names the collections it is holding back**, so a broken
  folder visibly explains why a collection is stuck partial. Collections are
  never pointed at directly — they light up as their folders return.
- As exact matches land, real files receive their metadata + tags + collection
  membership in the live DB. Then normal indexing reconciles new/changed files.

### Finishing

- When the pass completes, the user can **Finish** (accepting partials as-is) or
  keep resolving flagged folders / name-only matches.
- **No ✕ close button.** A single **Cancel** button is the only way out; mid-run
  it acts as **Stop** (with a confirm). The wizard cannot be half-dismissed and
  re-found — you either finish it or deliberately cancel it. This is why it needs
  no extra "reopen" UI.

### Library cleanliness on completion

- Auto collections that reconnect to **zero** files are **not created**.
- A deliberately hand-made, named-but-empty collection (`model_version =
  'manual'`) is **preserved** — it was intentional user intent, not a dead
  artifact. (The only exception to "no empty collections.")
- Partial collections contain only their connected members; missing members
  leave no trace in the library.

## UI specifics

- **Wizard chrome matches `InfoSheet`** exactly: `frame(width: 600, height:
  720)`, `padding(28)`, 24pt semibold title, 15pt semibold section heads, 13pt
  secondary body, vertical `ScrollView` that grows as needed. It does **not**
  use `SheetCloseButton`; its header carries the title and (when idle) any setup
  affordances, with the **Cancel** button as the sole dismissal.
- **Info modal addition:** `InfoSheet` gains a short **"Back Up & Restore"**
  section (same `section(_:_:)` style) explaining that Muse can export a backup
  file of collections, tags, and folders, and restore it on another Mac — so the
  feature is discoverable and users know to make a backup *before* migrating.

## Reuse of existing machinery

- **Content hash:** `HashService` (already computed during indexing).
- **Per-file payload:** the existing `Sidecar` Codable structures already
  serialize tags + every AI-derived field and are platform-neutral. The export
  is, per file, essentially a `Sidecar` plus its original path/name, alongside a
  collections manifest + roots + stars.
- **Hydration:** `SidecarHydrator`'s apply-onto-FileRow logic (`Sidecar.apply`,
  `Sidecar.tagRows`) is reused to write matched metadata into the DB.
- **Genuinely new code:** (a) export/import file assembly + the collections/
  stars/roots manifest, (b) UUID↔content-hash re-keying for collection
  membership, (c) the reconnect wizard UI and its match-and-stage engine.

## Edge cases

- **File present but edited** → fingerprint misses, name-only match offered for
  review; user accepts to reconnect (metadata applies; a changed file re-analyzes
  via the normal pipeline since `analyzed_hash` won't match).
- **Two folders both contain `photo.jpg`** → fingerprint disambiguates; only a
  genuine name-only fallback could collide, and those are review-gated.
- **Restore into a non-blank Muse** → supported; matching + reconcile merges
  rather than duplicating (this is what makes periodic backup viable).
- **Backup entry never matched** (file not on this Mac) → stays a wizard ghost;
  never enters the library; its collections show as partial/not-established.
- **Duplicate content across folders with different tags** → tags are exported
  per `(content_hash, original parent_dir)` so each location's tags reapply to
  the corresponding location, not blended.

## Testing approach

Pure/unit-testable seams, mirroring the codebase's existing test style:

- **Re-keying:** UUID→hash on export and hash→UUID on import round-trips
  (including unmatched members dropped, partial collections preserved with
  survivors only).
- **Match resolver:** fingerprint-first, filename-fallback, name-only flagged
  vs. exact silent; collision handling.
- **Collection materialization rules:** auto-empty dropped, manual-empty kept,
  partial shows survivors only.
- **Export/import serialization:** round-trip a fixture library (roots, tags
  manual+vision, AI metadata, collections w/ covers+exclusions+hidden, stars).
- **Tag re-keying:** `(content_hash, original parent_dir)` → new parent_dir.

The wizard view itself is not unit-tested (consistent with the project's
"UI views aren't unit-tested" stance); its logic lives in the pure resolver +
re-keying + materialization helpers above.

## Resolved decisions

- Match logic: **content fingerprint, filename fallback** (best practice; reuses
  existing hash).
- Reconnect flow: **dedicated, locked wizard** with **Reconnect All** batch run.
- Backup contents: **Option 1** — everything that makes Muse yours, incl. AI
  metadata; excludes thumbnails + OCR text.
- Collections: **auto-derived readout**, actioning is on folders; flagged folders
  name affected collections.
- Folder pointing: **point-at-one-parent auto-map + per-folder Locate…**.
- Empty collections: **auto-empty dropped, hand-made empty preserved**.
- Doubles as periodic backup: **yes** (restore reconciles into a non-blank Mac).
- Wizard chrome: **matches `InfoSheet` size/type**, scrolls, **no ✕ — Cancel
  only**.
- Info modal: **gains a "Back Up & Restore" section**.

## Open questions

None outstanding.
