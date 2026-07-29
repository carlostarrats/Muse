# Audit Ledger

Tracks which areas of Muse have been deliberately audited, when, and against which commit.

**Why this file exists.** The open-ended prompt — "review the codebase and QA in detail for health,
architecture, security, speed, find bugs, fix them, loop until green" — has no completion criterion.
Run repeatedly it does not converge on coverage; it converges on whatever is most *legible*. Each run
enters through the same door (the hero viewer, the grid, the analyze pipeline — the areas with the
richest constraint notes in `CLAUDE.md`, which is exactly what makes them easy to reason about), finds
real defects there, and reports success. Meanwhile the share extension, the backup/restore path, the
App Intents, the updater and the localization catalog can go pass after pass without being read once.
Finding something every time looks like thoroughness and is the opposite: it means the same shallow
region is being re-swept while the unread regions stay unread.

This ledger replaces "review the codebase" with **"audit the next unaudited area."** The exit condition
is concrete: every row audited at a commit at or after that area's last source change, and then
independently verified.

## How to use it

1. Pick the next row from **Audit order** below — or, once every row has a date, the row with the
   oldest `Audited at` whose `Last changed` is newer than it. Do not pick by interest.
2. Read that area's durable constraints in `CLAUDE.md` **first**, plus its `docs/session-log.md`
   entries — those invariants ARE the audit targets. An audit of an area with a listed invariant that
   never tested that invariant is not an audit of that area.
3. Audit with **probes, not reading**. Static re-reading finds close to nothing. What finds bugs here:
   - feeding hostile input to code the existing suite already agrees with (zero-byte files, 0×0 and
     40000×40000 images, orientation 5–8, CRLF, non-UTF-8 filenames, emoji/ZWJ, `Int.max` dimensions,
     paths that are prefixes of siblings, dataless iCloud placeholders);
   - asserting that **paired implementations of one concept actually agree** (screen packing vs the
     PDF exporter; `ImageHeaderSizeCache` vs `AspectRatioCache`; tile rect vs hero flight endpoint;
     sidecar write vs sidecar merge; the sidebar row's four drawing sites);
   - walking every path that rewrites `parent_dir` or `file_id` and checking that `tags`, `notes` AND
     `collection_members` all move together;
   - checking failure/cancel paths, not happy paths (what is orphaned when this throws mid-way?).
4. For anything in the hero open/close path, or any sandbox/filesystem/entitlement behavior:
   **instrument the running app** (`sample <pid>`, a `NSTemporaryDirectory()` trace). A reasoned fix in
   that area has been wrong nearly every time it was tried. See
   `docs/hero-viewer-open-close-handoff.md`. A green build and a green suite are not evidence the
   feature works — see the `verify-runtime-not-just-tests` rule.
5. Update the row: date, commit audited at, one-line finding summary. Write `none` if clean — a clean
   audit is a result and stops the area being re-swept.
6. `Verified at` gets a date only after a **later, independent pass tried to break the fixes and
   failed**. A fix and the test written beside it in the same pass share the mental model that produced
   the bug; that pair is not evidence.
7. If the audit produces a rule that can never be broken, it goes in `CLAUDE.md` under **Durable
   constraints & gotchas** — not here. Narrative goes in `docs/session-log.md`.

Findings themselves live in commit messages, `CLAUDE.md` and the session log. **This file only records
coverage.**

## Audit order

Risk-weighted, for while rows are still `never`. Data loss and privacy egress first, because those are
the two classes Muse cannot take back once shipped; then correctness of identity; then UI.

1. Identity & indexing (a wrong split/merge is silent data loss)
2. Tags · notes · ratings · search (the `(file_id, parent_dir)` grain; every relocation path)
3. Filesystem: roots, bookmarks, moves, renames, trash (sandbox + permanent delete)
4. Drive share + share page (the only network egress; metadata stripping is fail-closed by design)
5. Per-kind viewers (the passive-egress surface: SVG, AVFoundation, QuickLook)
6. iCloud sync & sidecars (multi-device last-writer-wins)
7. Backup / restore / share extension (never audited, moves user data)
8. Thumbnails & decode budget (OOM on mere folder open)
9. Analyze pipeline & Vision
10. Collections, clustering, smart rules
11. Duplicates
12. Grid, layout geometry, selection, keyboard
13. Hero viewer & flight
14. Sidebar & modals
15. Export: collection PDF
16. App shell, settings, App Intents, updater
17. Metadata import (keywords & ratings)
18. Localization completeness

## Coverage

`Last changed` is the most recent commit touching that area's sources, as of 2026-07-28 (HEAD `e63f137`).

| Area | Key sources | Last changed | Audited at | Verified at | Findings |
|---|---|---|---|---|---|
| Identity & indexing | `Indexing/Indexer`, `HashService`, `Filesystem/PathReconciler` | 57fb329 (07-28) | 07-28 | never | 3 confirmed: recursive reconcile mass-marked rows dead under an unreadable subfolder; `hashConcurrency` was a no-op (measured peak 1) and `inFlightHashes` unreachable; collision edit left the file unsearchable by its own name. 1 refuted — hidden-file dead-marking (`showHidden` has no UI and is always false) |
| Tags · notes · ratings · search | `Database/` (`TagStore`, `TagScope`, `NoteStore`, `RatingLoader`, `SearchService`, `SearchBridge`, `Housekeeping`, `Records`, `Database`) | aa22380 (07-28) | 07-28 | never | 3 confirmed: library-wide rename reachable on a rating chip (destroys every rating at that level); free-text tag entry accepted ★ runs (two ratings on one file); tag/note search dropped `parent_dir` and leaked the other folder's duplicate. 2 refuted — unchunked `IN` in search (system SQLite caps at 500k vars, not 999) and `notes` missing from the Housekeeping purge (FK cascade covers it, `foreignKeysEnabled = true`) |
| Filesystem: roots, moves, renames, trash | `BookmarkStore`, `FolderTree`, `FolderWatcher`, `FolderOps`, `FileMover`, `FileMoveMigration`, `FolderRenameMigration`, `FolderStat*`, `TrashManager`, `StarStore` | 2a87d49 (07-28) | 07-28 | never | 1 confirmed: `FolderStats.compute` reported an unlistable folder as 0 files, so the iCloud row's `.unknown` guard could never fire and a full folder could hide. 6 refuted (all probed, not reasoned): case-only rename works on the real volume for files AND folders; file rename DOES validate (`FileNameSplit`, mirrors `FolderOps.sanitize`); no path-valued smart rules for the rename migration to miss; deletions still refresh the grid; the pin's security scope is balanced across a stale re-mint; a failed move migration is caught and degrades, not corrupts. Noted, not fixed: a root whose volume is absent at launch never re-activates for the session |
| Drive share + share page | `Sharing/Drive/*`, `web/share/*` | cd4f241 (07-07) | never | never | — |
| Per-kind viewers | `Viewers/` (SVG, PDF, video, audio, markdown, font, model, text), `Views/ViewerRouter`, `QuickLookFallback`, `AVURLAsset+NoNetwork` | f03cc22 (07-28) | never | never | — |
| iCloud sync & sidecars | `ICloudZone`, `Sidecar`, `SidecarStore`, `SidecarHydrator` | 48a5057 (07-07) | never | never | — |
| Backup / restore / share extension | `Backup/*`, `Views/Backup/ReconnectWizard`, `MuseShareExtension/` | 4571241 (07-28) | never | never | — |
| Thumbnails & decode budget | `ThumbnailCache`, `DecodePermit`, `ImageHeaderSizeCache`, `Views/AspectRatioCache` | dc0633c (07-28) | never | never | — |
| Analyze pipeline & Vision | `AnalyzePipeline`, `Vision/VisionServices`, `Core/PaletteExtractor`, `ColorTagger`, `VisionTagger`, `IntentBackfill` | e33888d (07-28) | never | never | — |
| Collections, clustering, smart rules | `Intelligence/Collections/*`, `Core/HybridClusterer`, `SemanticSearch`, `SentenceEmbedder`, `VectorMath`, `Components/ReclusterGate` | e33888d (07-28) | never | never | — |
| Duplicates | `Dedup/DuplicateFinder`, `DuplicateDeleteRules`, `Views/DuplicatesView` | d1c3f92 (07-28) | never | never | — |
| Grid, layout, selection, keyboard | `Views/GridView`, `Components/MasonryGeometry`, `JustifiedRowsGeometry`, `GridSelection`, `GridKeyboardNav`, `GridScrollReveal`, `Views/PageScroll*` | dde5d7c (07-28) | never | never | — |
| Hero viewer & flight | `Views/Viewer/*` (`HeroImageViewer`, `HeroStage`, `ViewerGeometry`, `ViewerBackdrop`, `HeroVideoViewer`), `Viewers/HeroPalette`, `Views/ToolbarFade`, `Components/PartingField` | f03cc22 (07-28) | never | never | — |
| Sidebar & modals | `Views/SidebarView`, `Views/Sidebar/*`, `Views/Modal/*`, `Components/ReorderMath`, `RootDedupe`, `ICloudSidebarVisibility`, `CollectionPickerLayout`, `TagSuggest` | d4f6302 (07-28) | never | never | — |
| Export: collection PDF | `Export/CollectionPDFExporter`, `CollectionPDFLayout`, `PaperSize`, `Views/CollectionPDFSave` | 4571241 (07-28) | never | never | — |
| App shell, settings, intents, updater | `ContentView`, `MuseApp`, `Models/AppState*`, `Settings/*`, `Agents/AppIntents`, `Updates/Updater`, `Components/EscapeAction` | f5f4c5f (07-28) | never | never | — |
| Metadata import (keywords & ratings) | `Import/*` | 4571241 (07-28) | never | never | — |
| Localization completeness | `Localization/VocabularyLocalizer`, `Localizable.xcstrings`, `VisionVocabulary.json` | f03cc22 (07-28) | never | never | — |

## Notes

- Muse's highest-consequence areas are the ones with the fewest tests, not the most: `MuseTests` is
  pure-logic-heavy (geometry, sort, selection, rules) and UI/integration-shallow. A green suite says
  nothing about the sidebar, the viewers, the share extension or the updater.
- Three areas carry standing "do not trust code reading" warnings and must be audited by instrumenting
  the running app: the hero open/close path, anything sandbox/entitlement-shaped (a `/tmp` write is
  silently denied; `NSLog` does not reach `log stream`), and packaging/signing.
- `BUILD SUCCEEDED` is not proof the running app has the change — `stat` the built binary's mtime
  before judging anything visually. This has already cost a full session once (2026-07-28).
- The Drive row is the only network egress in the app and its stripping is fail-closed by design; audit
  it before any release that touches `Sharing/`, not after.
