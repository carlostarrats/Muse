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
| Identity & indexing | `Indexing/Indexer`, `HashService`, `Filesystem/PathReconciler` | 57fb329 (07-28) | 07-28 | 07-28 | 3 confirmed: recursive reconcile mass-marked rows dead under an unreadable subfolder; `hashConcurrency` was a no-op (measured peak 1) and `inFlightHashes` unreachable; collision edit left the file unsearchable by its own name. 1 refuted — hidden-file dead-marking (`showHidden` has no UI and is always false) |
| Tags · notes · ratings · search | `Database/` (`TagStore`, `TagScope`, `NoteStore`, `RatingLoader`, `SearchService`, `SearchBridge`, `Housekeeping`, `Records`, `Database`) + `Indexing/Indexer`, `Filesystem/FileMoveMigration` | aa22380 (07-28) | 07-29 | 07-28 | 3 confirmed 07-28: library-wide rename reachable on a rating chip (destroys every rating at that level); free-text tag entry accepted ★ runs (two ratings on one file); tag/note search dropped `parent_dir` and leaked the other folder's duplicate. **+1 confirmed 07-29 (delta pass): the rating-exclusivity invariant was NOT enforced in the DB identity-merge helpers — `Indexer.unionTags` (collision re-home) and `FileMoveMigration.migrateTags` (in-app move) key conflicts on the exact label, so a `★★` scope merged into a `★★★★` scope kept both, doubling the rating and leaking a two-rating sidecar. Fixed via `Indexer.collapseRatings` (highest wins), +3 tests. The SAME finding as rows 6 & 7 arriving through a fifth door — the exact per-area-sweep pattern.** 2 refuted — unchunked `IN` in search and `notes` missing from Housekeeping purge (FK cascade covers it) |
| Filesystem: roots, moves, renames, trash | `BookmarkStore`, `FolderTree`, `FolderWatcher`, `FolderOps`, `FileMover`, `FileMoveMigration`, `FolderRenameMigration`, `FolderStat*`, `TrashManager`, `StarStore` | 2a87d49 (07-28) | 07-28 | 07-28 | 1 confirmed: `FolderStats.compute` reported an unlistable folder as 0 files, so the iCloud row's `.unknown` guard could never fire and a full folder could hide. 6 refuted (all probed, not reasoned): case-only rename works on the real volume for files AND folders; file rename DOES validate (`FileNameSplit`, mirrors `FolderOps.sanitize`); no path-valued smart rules for the rename migration to miss; deletions still refresh the grid; the pin's security scope is balanced across a stale re-mint; a failed move migration is caught and degrades, not corrupts. Noted, not fixed: a root whose volume is absent at launch never re-activates for the session |
| Drive share + share page | `Sharing/Drive/*`, `web/share/*` | cd4f241 (07-07) | 07-28 | 07-28 | **none** — clean. Probed: the inflate cap truly bounds (65 KB → 64 MB uncapped, exactly 4 MB capped, no growth); OAuth validates `state`, PKCE S256, no secret, revoke in the POST body, `invalid_grant` distinguished from transient failure; tokens Keychain-only device-only; `ensureMuseRoot` self-heals a stale root id, so an account switch can't strand uploads; publish is fail-closed (any post-folder failure deletes the folder, cleanup runs in a fresh Task so cancellation can't skip the DELETE); page is `default-src 'none'`, `textContent`-only, id-regex + field caps + bidi/zero-width sanitize. Web tests are ~50 assertions, not the 1 `node --test` reports |
| Per-kind viewers | `Viewers/` (SVG, PDF, video, audio, markdown, font, model, text), `Views/ViewerRouter`, `QuickLookFallback`, `AVURLAsset+NoNetwork` | f03cc22 (07-28) | 07-28 | 07-28 | 1 confirmed: AUDIO reached QuickLook's unrestricted AVFoundation on folder open — the video egress rule never extended to `.m4a`, the same ISO-BMFF container. 3 refuted: no bare `AVURLAsset`/`AVPlayer` anywhere; `ViewerRouter` routes video/audio to the restricted players; the SVG `WKContentRuleList` still installs before load and fails closed |
| iCloud sync & sidecars | `ICloudZone`, `Sidecar`, `SidecarStore`, `SidecarHydrator` | 48a5057 (07-07) | 07-28 | 07-28 | 2 confirmed, both the rating-exclusivity rule breaking across devices: the sidecar tag UNION kept BOTH sides' ratings; hydration inserted a sidecar rating alongside a different local one. 2 refuted — `resolveForWrite`'s note ownership split is correct, and the analyze-merge note rule already survives a not-yet-hydrated note |
| Backup / restore / share extension | `Backup/*`, `Views/Backup/ReconnectWizard`, `MuseShareExtension/` | 4571241 (07-28) | 07-28 | 07-28 | 2 confirmed: the share extension reported SUCCESS for every failure incl. signed-out-of-iCloud, so shared files vanished silently; restore could add a second rating to a file the user had since rated. Refuted: backup keys membership/cover by content hash (portable), and `uniqueDestination` never clobbers |
| Thumbnails & decode budget | `ThumbnailCache`, `DecodePermit`, `ImageHeaderSizeCache`, `Views/AspectRatioCache` | dc0633c (07-28) | 07-28 | 07-28 | 1 confirmed: `renderedVariants` had drifted from the sizes actually requested (Duplicates tile; hero fallback used a continuous viewport-derived size), so `invalidate` couldn't drop them and an edited file served a stale thumbnail forever — including in the Duplicates modal, where the picture drives a delete decision. Refuted: decode budget, permit weighting and the gate's release loop all behave as documented |
| Analyze pipeline & Vision | `AnalyzePipeline`, `Vision/VisionServices`, `Core/PaletteExtractor`, `ColorTagger`, `VisionTagger`, `IntentBackfill` | e33888d (07-28) | 07-28 | 07-28 | **none** — clean. Verified: every external entry point goes through a claiming wrapper (no bare `analyze(folder:)`/`analyze(file:)` caller exists); `cancelRequested` is reset at the start of both inner passes, so a cancel can't poison the next one; `withinDecodeBudget` still runs BEFORE the bounded 4096 decode; `analyzeOne` captures the hash before Vision and the write transaction refuses to commit if it moved; auto-tag is opt-out-gated while the manual paths are not |
| Collections, clustering, smart rules | `Intelligence/Collections/*`, `Core/HybridClusterer`, `SemanticSearch`, `SentenceEmbedder`, `VectorMath`, `Components/ReclusterGate` | e33888d (07-28) | 07-28 | 07-28 | **none** — clean. Refuted: smart tag/rating rules ignoring `parent_dir` is CONSISTENT with manual membership (both file_id-keyed by design — do not "fix" one without the other); the unescaped `%`/`_` in the filename LIKE only over-fetches and the exact Swift check re-narrows; the auto-collection hard DELETE is guarded by protected+hidden and fails closed; all 5 visibility consumers still check BOTH signals. Noted: a color rule re-scans every palette per evaluation |
| Duplicates | `Dedup/DuplicateFinder`, `DuplicateDeleteRules`, `Views/DuplicatesView` | d1c3f92 (07-28) | 07-28 | 07-28 | 1 hardening: the never-empty-a-group invariant was maintained incrementally but NOT re-asserted at the irreversible step, so it rested on SwiftUI having delivered the latest `onChange` first; `deleteSelected` now re-derives it. Refuted: seeding, cross-group rescue and the swap rule all behave as specified |
| Grid, layout, selection, keyboard | `Views/GridView`, `Components/MasonryGeometry`, `JustifiedRowsGeometry`, `GridSelection`, `GridKeyboardNav`, `GridScrollReveal`, `Views/PageScroll*` | 0dcf435 (07-29) | 07-29 | 07-28 | **none** — clean. Verified 07-28: paging is keycode-only (never the `.function` flag the arrows carry inherently); every narrowing input prunes or clears the selection; the tile keeps its path-stable `.id` over the index-keyed virtualized `ForEach`; the PDF's row pagination consumes `JustifiedRowsGeometry.rows`; the wholesale swap keys on the RESOLVED `tagFilterGeneration`. Delta 07-29 (Polish 28 grid-margins-track-spacing / equal sliders): re-swept clean — `MasonryGeometry`/`visibleIndices` bounds still safe, selection pruning intact |
| Hero viewer & flight | `Views/Viewer/*` (`HeroImageViewer`, `HeroStage`, `ViewerGeometry`, `ViewerBackdrop`, `HeroVideoViewer`), `Viewers/HeroPalette`, `Views/ToolbarFade`, `Components/PartingField` | b3af58d (07-29) | **static only (07-29)** | never | All 6 documented guards verified PRESENT (the three `!isClosing` exits + the mid-res swap; no `withAnimation` around the `viewerDismissing` write; `sourceRect` from the header cache; retarget shrink-only, once, degenerate-target exception; ToolbarFade covers the titlebar accessory). **+1 confirmed 07-29 (delta pass, a STRUCTURAL omission, not a timing bug — so valid by reading): the mid-burn `onDisappear` delete cleanup removed the trashed file from `currentFiles` but omitted the paired `dropFromActiveCollection` that every sibling delete path has, so a delete completing mid-burn while a collection stays active (window close+reopen) left a ghost tile that rides into Save-to / Share Drive Link. Fixed.** Still owes the timing runtime pass: open/close + Escape + arrow-flip on a >100 MP file, `sample` on any stall (the Polish 28 open-bounce / staggered-converge changes are unmeasured) |
| Sidebar & modals | `Views/SidebarView`, `Views/Sidebar/*`, `Views/Modal/*`, `Components/ReorderMath`, `RootDedupe`, `ICloudSidebarVisibility`, `CollectionPickerLayout`, `TagSuggest` | cc22c97 (07-29) | 07-29 | 07-28 | **none** — clean. Verified 07-28: no `.onDrag` on any sidebar row (only grid tiles); both reorderable lists are non-lazy `VStack`s keyed by id; all four row-drawing surfaces read the shared `SidebarView` geometry constants. Delta 07-29 (feat/next-148 alert→in-window-card migration + Polish 28 headers/selection-fill/"+ Create New" menu): re-swept clean — the Drive publish's **cancel-on-dismiss SECURITY invariant survives** (card built only while presented, `.onDisappear { service.cancel() }` fires on every dismissal path); all 20 modal states are in `modalPresented` (gates the grid key-catcher); the three onChange-raised tag confirms are consumed by an always-mounted shell consumer; prompt drafts stay local `@State` |
| Export: collection PDF | `Export/CollectionPDFExporter`, `CollectionPDFLayout`, `PaperSize`, `Views/CollectionPDFSave` | 4571241 (07-28) | 07-28 | 07-28 | **none** — clean (the audio-to-QuickLook egress found here was fixed under row 5, its owning area). Verified: the decode-bomb guard runs before every export decode; row pagination consumes the screen packer; layout is unit-tested against the on-screen geometry |
| App shell, settings, intents, updater | `ContentView`, `MuseApp`, `Models/AppState*`, `Settings/*`, `Agents/AppIntents`, `Updates/Updater`, `Components/EscapeAction` | f5f4c5f (07-28) | 07-28 | 07-28 | **none** — clean. Verified: App Intents never read `currentFiles` (they enumerate the folder); Sparkle feed is HTTPS with `SUPublicEDKey` set and the sandbox installer-launcher service enabled; the OAuth redirect scheme in Info.plist matches the derived scheme from `DriveConfig.clientID` EXACTLY (a mismatch would hang sign-in with no error); `AppDelegate` implements `selectAll(_:)` + `validateMenuItem` and secure restorable state |
| Metadata import (keywords & ratings) | `Import/*` | 4571241 (07-28) | 07-28 | 07-28 | **none** — clean. This was the ONE write path already guarding rating glyphs before this audit, and it still does; the rating write goes through the single exclusive seam and only fills a gap, never overwrites; keywords are trimmed, empty-rejected and case-insensitively de-duplicated; ratings clamp (>5 → 5, 0/negative/absent → nil, so Lightroom's −1 "rejected" doesn't become a star) |
| Localization completeness | `Localization/VocabularyLocalizer`, `Localizable.xcstrings`, `VisionVocabulary.json` | f03cc22 (07-28) | 07-28 | 07-28 | 1 confirmed (self-inflicted, this audit): the two share-extension error strings added in row 7 shipped unwrapped — now `String(localized:)`. Catalog is otherwise complete: 611 keys, 0 genuinely untranslated (the 6 flagged are `=`/`≤`/`≥`/`MB`/`MP`/empty — symbols and units that are identical in French). 36 `stale` keys are the documented `NSLocalizedString(variable)` case and must NOT be pruned. **Note: the extension has no strings catalog of its own**, so its two strings resolve to English until one is added |

## First full pass — 2026-07-28

All 18 rows walked in one session. **17 audited, 1 (hero viewer) static-only by
its own rule.** 15 defects confirmed and fixed, 25 suspicions refuted.

The single most useful pattern: **one invariant, enforced at some write paths and
not others.** Rating exclusivity ("a photo has at most one star rating") was
correct in the rating control and the metadata import, and broken in five other
places that can also create a rating — free-text tag entry, library-wide tag
rename, the sidecar sync merge, sidecar hydration, and backup restore. Nothing
was wrong with the rule; it just wasn't applied everywhere the rule could be
reached. Rows 2, 6 and 7 are all the same finding arriving through different
doors, which is exactly what a per-area sweep surfaces and a "review the
codebase" prompt does not.

Second pattern: **a failed read masquerading as an empty result.** An unreadable
directory returns "no files" from `FileManager`, and three places believed it —
the recursive reconcile (marked rows dead), the folder stats (hid a full iCloud
folder), and, historically, the enumeration guard that only checked the top
folder. Every one of these was found by probing the failure mode on real disk,
never by reading.

## Verify round — 2026-07-28, all 18 rows

Every fix was re-attacked rather than re-read. The round found **3 defects
introduced by the audit's own fixes**, one of them a real bug:

- Making `renameLabel` refuse a rating left its CALLER unchanged, so a refused
  rename still rewrote the active-tag filter to the new name — an empty grid
  under a chip matching nothing. And the fix had only covered the chip's context
  menu: the **Tags menu-bar item (⌃⌘R) still offered Rename for a rating chip**,
  because it reads `singleActiveTag`. Right in isolation, wrong in context.
- The folder-scope narrowing duplicated the `0.45` semantic threshold instead of
  reading the one the merge is given; the two could drift apart.
- Growing `renderedVariants` from 2 to 7 raised main-thread work in
  `invalidate`, which `markContentChanged` loops per changed file. Measured:
  `removeItem` on a missing path costs ~7µs (it builds an NSError) against
  ~1.5µs to check existence, so the delete is now probed first.

Fixes that had only pure-helper coverage were given real evidence:

| Fix | How it was verified |
|---|---|
| Indexer moved off the actor | 32 concurrent reconciles of identical content → exactly 1 row, 32 alive paths; 32 distinct → 32 rows + 32 FTS rows. Attacks the "GRDB serializes everything" assumption the change rests on — if it didn't hold, both would insert and trip the `content_hash` UNIQUE, silently dropping a file. |
| Audio kept from QuickLook | Built a real `.m4a` with embedded PNG art via `AVAssetExportSession`, read it back through the RESTRICTED asset, decoded it. Album art did NOT regress to the type icon — previously an assumption. |
| Sidecar hydration rating rule | Real migrated DB: a syncing `★★★★` does not join a local `★★`; it lands when the file has none; a double-rated sidecar hydrates one. |
| Restore rating rule | Real migrated DB: restore REPLACES a differing local rating (the deliberate opposite of hydration), leaves it alone when the archive has none, collapses a double-rated archive. |
| Unreadable-folder handling (rows 1 & 3) | chmod-000 directories on real disk, in both the recursive walk and the stat pass. |

**17 rows carry a `Verified at`. Row 13 (hero viewer) stays `static only`** — its
guards are verified present, but its rule is diagnose-by-instrumenting and its
failures are timing ones invisible to reading. It owes a runtime pass:
open/close + Escape + arrow-flip on a >100 MP file, `sample` on any stall.

923 unit tests + 6 UI tests green.

## Post-audit change pass — 2026-07-28

The fixes that came out of running the app (progress pill, thumbnails, the
undecodable-file loop, pill placement) moved several rows past their audit, so
the delta was re-reviewed under the same rules. Rows touched: **1** (Indexer,
trace marks only), **6** (`SidecarHydrator.apply` made internal for tests),
**8** (thumbnails), **9** (analyze), **10** (CollectionsEngine, trace marks
only), **16** (ContentView / MuseApp).

Reviewing that diff found **4 defects in the session's own fixes**:

- The grace-window tick was a `Timer.publish(...).autoconnect()`, so it woke the
  main runloop 3×/second for the entire life of the app, idle or not — a
  background hum in an app whose whole point is not having one. Now a
  `.task(id: isActive)` loop that exists only while the pill is up.
- The completion hold was re-scheduled on every tick while `isFinishing` (~2
  redundant tasks per run; `reset()` was guarded, so harmless but pointless).
  Scheduled once now, and the claim is cleared when a run resumes so it can
  never latch.
- `PhaseTrace.mark` took plain `String`s, and Swift evaluates arguments before
  the callee — so every index batch and FSEvents delivery built its interpolated
  detail string even with tracing OFF. `@autoclosure` makes a disabled trace
  genuinely free.
- The pill's overlay carried two stacked comment blocks whose first half had
  become wrong (it no longer centres).

Three review rounds; the third found only a stale comment. 929 unit tests + 6 UI
tests green.

## Delta pass — 2026-07-29

The first full pass audited every row at `e63f137`. Since then three feature
branches landed on top (feat/next-148 alert→in-window-card migration, feat/next-149
Drive-modal headers, Polish 28 sidebar/grid/hero polish) plus the release-notes
work. This pass audited **that delta only** — the ledger's own rule (audit the
area whose `Last changed` is newer than its `Audited at`), not a re-sweep of
already-covered ground. Five parallel lenses: security/egress, data-identity
reconciliation, concurrency/leaks, correctness/resource-orphaning, and a focused
trace of the modal-card migration's lifecycle + security invariants.

**2 confirmed defects, both fixed; 3 lenses clean.**

- **Rating exclusivity not enforced in the DB identity-merge helpers** (row 2).
  `Indexer.unionTags` and `FileMoveMigration.migrateTags` key their tag conflict
  on the exact label, so a `★★` scope merged into a `★★★★` scope kept both — the
  same one-rating-per-photo invariant that rows 6 and 7 found broken at the
  sidecar-merge, hydration, and restore seams, now found at a **fifth** door.
  Fixed with `Indexer.collapseRatings` (highest run wins, matching
  `Sidecar.collapsingRatings`; `TagRow` has no timestamp), called after both
  merges. +3 tests (`TagFolderScopeTests`, `FileMoveMigrationTests`). This is the
  same lesson the first pass drew in bold: *one invariant, enforced at some write
  paths and not others* — the per-area sweep keeps surfacing the un-covered doors.
- **Mid-burn hero delete leaves a collection ghost** (row 13). The
  `HeroImageViewer.onDisappear` path that finishes a delete when the viewer is
  unmounted mid-burn removed the file from `currentFiles` but omitted the paired
  `dropFromActiveCollection` every other delete path carries, so a delete
  completing while a collection stays active (window close+reopen) leaves a ghost
  tile that rides into Save-to / Share Drive Link. A structural omission (an
  absent call vs. its four siblings), not a timing bug, so valid to find by
  reading — but the row's timing runtime pass is still owed and now also covers
  the Polish 28 open-bounce.

**Clean:** security/egress (Drive, SVG, AVFoundation, QuickLook, decode budget —
the AV-extension edge is covered by the `classifyByUTType` fallback);
concurrency/leaks (no retain cycles, no free-running timers, isolation correct;
a handful of one-shot `withAnimation`-around-`@Published` writes deviate from the
letter of the no-animate-AppState rule but are navigation/delete/mood events, not
the per-frame close-flight writes that caused the measured stall — left as-is
rather than changed by reasoning in instrument-only UI); the modal-card migration
(all six lifecycle/security invariants intact, most importantly the Drive
cancel-on-dismiss).

939 unit tests + 6 UI tests green.

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
