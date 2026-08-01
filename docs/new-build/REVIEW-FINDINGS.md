# Specs 01–07 review — findings

Branch `new-product-build-1`, diff base `526d8a9` (`git merge-base main HEAD`).
326 files changed, 37,296 insertions, 243 new files.

Baseline re-verified at the start of this review: **1,748 tests, 2 skipped, 0
failures** (`xcodebuild … -only-testing:MuseTests test`, `** TEST SUCCEEDED **`).
Any failure after this point is the review's.

Every row below is marked **confirmed** (I read the code and can quote it) or
**inferred** (reasoned from the code but not proved). Nothing is acted on until
it is confirmed.

---

## Pass A — systematic sweeps

### A0. Correction to the review prompt's `AppState` figures

The prompt states `AppState.swift` measures "1505 LOC and 85 `@Published` (93
across all `AppState*.swift`)". **Confirmed: the 85/93 counts are wrong** — they
count comment lines that mention `@Published`. Counting declarations only
(`grep -c '@Published var'`):

| | merge base `526d8a9` | HEAD | delta |
|---|---|---|---|
| `AppState.swift` LOC | 1,395 | 1,505 | +110 |
| `@Published var` in `AppState.swift` | 70 | 75 | +5 |
| `@Published var` in all `AppState*.swift` | 70 | 75 | +5 |

Every `@Published` lives in `AppState.swift`; the sixteen `AppState+*.swift`
extensions declare none. So the frozen budget (~1380 LOC / ~70 `@Published`) was
**already at its `@Published` ceiling and ~15 LOC over on size before this
branch**, and Specs 01–07 added five properties and 110 lines — not twenty-three
properties. The remediation is proportionally smaller than the prompt assumed.
See table A8 for the five and their attribution.

---

### A1. Launch work

Everything `MuseApp.body`'s single `.task` fires, in source order. It is one
`.task` on the `WindowGroup` content, so all of this begins the moment the first
window appears.

| # | Task | Trigger | Scans | Cost @10k | Cost @100k | Per-launch cap | Sequenced against |
|---|---|---|---|---|---|---|---|
| 1 | `PhaseTrace.begin()` | launch, sync/main | — | ~0 | ~0 | n/a | — |
| 2 | `ThumbnailCache.enforceDiskCap()` | launch | whole thumbnail dir | detached, `.background` | detached | none (size-capped 2 GB) | nothing — detached |
| 3 | `OutputRender.sweepRenderTemps()` | launch, **sync on main** | `tmp/muse-render/*` | ~0 (dir usually absent) | ~0 | age 24 h | blocks 4–14 |
| 4 | `EditStackIndex.installProvider` + `EditStore/AnalysisStatusStore.installHost` | launch, sync/main | — | ~0 | ~0 | n/a | correctly BEFORE all pixel work |
| 5 | `AnalysisStatusStore.refresh(force:)` | launch | DB count query | small | small | none | — |
| 6 | `EditStore.rebuildIndex()` | launch, `Task {}` | **full `edits ⋈ paths` join**, decodes every stack JSON, + full `edit_versions ⋈ paths` join | ms | O(#edits); every stack JSON decoded and held in RAM | none | nothing |
| 7 | `Housekeeping.pruneUnreachable` | launch, **awaited inline** | full `paths` scan | small | O(n) | none | **blocks 8–14** |
| 8 | `IntentBackfill.run()` | launch, `Task {}` | all screenshot-tagged files with `intent_model_version IS NULL`; **one write transaction per file** | small | O(#screenshots) tx | **none** | nothing |
| 9 | `PhotoHeaderBackfill.run()` | launch, `Task {}` | header read per stale file, 4-wide; **one extra `queue.read` per file** | 5,000 files | 5,000/launch → 20 launches | 5,000 | nothing; chains #11 + `SearchFacets` on write |
| 10 | `DeepAnalysisBackfill.run()` | launch, `Task {}` | **decode @1024px + Vision (faces/pets/sharpness/noise) + CLIP** per stale file, 2-wide | 5,000 | 5,000/launch → 20 launches | 5,000 | nothing |
| 11 | `GeocodeBackfill.run()` | launch, `Task {}` | all files with `lat` and stale/missing `places` row; loads ~7 MB GeoNames + builds a k-d tree | O(#geotagged) | **unbounded** | **none** | nothing; **can run concurrently with the copy #9 chains** |
| 12 | `PerfBaseline.run()` | launch, env-gated | — | 0 (off) | 0 (off) | n/a | — |
| 13 | `announcementStore.fetchIfNeeded()` | launch, `Task {}` | one HTTPS GET | — | — | once/launch, off-able | nothing |
| 14 | `DriveExpirySweeper.sweep` | launch, **awaited inline** | local records; network only if signed in + something due | — | — | — | last |

**Nothing sequences 6, 8, 9, 10, 11.** They start together and contend for the
single GRDB serial queue, which is the same queue the first folder open needs.
`PhotoTraits.currentVersion` is 2 (bumped by v22), which makes *every existing
`photo_traits` row* version-behind, so #10 re-decodes and re-Visions the entire
library at 5,000/launch on an upgrade — 20 launches for a 100k library, each
launch spending its first minutes at 2 concurrent Vision passes.

Measured against foundation §9 ("analysis is background, throttled and pausable,
photos browsable immediately, cold start budgeted") this is the decided-criteria
violation the prompt predicted. Ranked findings in A11.

---

### A2. Full-library scans and backfills

| Pass | Trigger | Cap | Invalidated by | Concurrent with itself / another over the same rows? |
|---|---|---|---|---|
| `IntentBackfill` | launch | **none** | `intent_model_version IS NULL` | no |
| `PhotoHeaderBackfill` | launch | 5,000 | `coords_scanned_hash != content_hash` or `exif_scanned_hash != content_hash` | no |
| `DeepAnalysisBackfill` | launch; **also `ClipModelStore` after a successful model install** | 5,000 | `traits_scanned_hash != content_hash`, `traits_version < 2`, `embedded_hash`/`model_generation` mismatch | **YES** — a model install during a launch pass starts a second concurrent run over the same rows; flush guards content-hash, not concurrent scans |
| `GeocodeBackfill` | launch; **also chained from `PhotoHeaderBackfill` on any write** | **none** | `geocoded_hash != content_hash`, `dataset_version` bump | **YES** — the launch copy and the chained copy overlap on a large library; both load the 7 MB dataset and build a k-d tree |
| `AnalyzePipeline.analyzePending` | folder open, FSEvents, reconnect | per-folder | `analyzed_hash != content_hash` | self-guarded by a claim set |
| `AutoStacker.run` | end of an analyze pass, per-folder `StacksStore.reload` | pass ids | `stack_members` virginity | re-checked inside the write |
| `SearchFacets.refresh` | after every backfill write, every analyze pass, every import | none | — | **YES** — three launch backfills can call it concurrently; 4 GROUP BY scans, one an unindexable `strftime` over all of `photo_meta` |
| `CollectionsEngine.recluster` | IntentBackfill, 2× in AnalyzePipeline | none | — | possible |
| `PlacesStore.reload` / `StacksStore.reload` | geocode write / folder load | none | — | idempotent |
| `EditStore.rebuildIndex` | launch **only** | none | — | see A7 — **not called after folder rename or file move** |
| `ClipPromptVectors.refreshAll` | after model install | none | model generation | no |

---

### A3. Main-thread work

| Site | What | Verdict |
|---|---|---|
| `EditStore.warmIndex` → `EditStackIndex.merge` → `makeEntry` → `EditRenderer.canRender` → `LutRegistry.rgbaCube` | **synchronous `queue.read` of a multi-MB LUT blob, on `@MainActor`** | **confirmed defect.** `LutRegistry`'s own header says "must never be called on the main thread"; `EditRenderer.canRender`'s says "never call on the main thread for a LUT-bearing stack". `EditStore` is `@MainActor` and `warmIndex` runs on every save (autosave: every 400 ms of editing). |
| `EditStore.applySaveConsequences` → `warmIndex` + `refreshVersionCounts` | **two full-table joins per autosave** (`edits ⋈ paths` unfiltered then filtered in Swift; `edit_versions ⋈ paths` grouped) | **confirmed.** Both are `await`ed off-main, so not a main-thread stall, but they are O(library edits) per 400 ms slider settle. |
| `OutputRender.sweepRenderTemps()` in `MuseApp.task` | `contentsOfDirectory` + `removeItem` synchronously on main at launch | confirmed, low severity (dir is usually absent or tiny) |
| `WorkThrottleStore.waitUntilRunnable()` | `@MainActor` hop per backfill chunk | by design, cheap |
| `withAnimation` around an `AppState` write | **none added by this branch** (`git diff` over all of `Muse/Muse` finds 5 new `withAnimation` calls, all on local view state) | clean |
| per-keystroke `@Published` binding | search field is debounced 250 ms in `ContentView`; `SearchFacets` is explicitly refreshed on writes, never per keystroke | clean |
| unbounded debounce | none found; `FolderStatCache` has a `maxWait` cap | clean |

---

### A4. Algorithmic cost

| Site | Shape | Verdict |
|---|---|---|
| `ClipIndex.matches` | `LIMIT chunkRows OFFSET offset` paging over an ordered PK | **confirmed O(n²/chunk).** SQLite must walk and discard `offset` rows per page: 800k rows / 4,096 ≈ 195 pages, ~78M discarded row-visits. Keyset pagination (`WHERE file_id > ?`) is O(n). The file's own header claims the streaming design satisfies "no code may assume the whole matrix fits in RAM" — the RAM claim holds, the time claim doesn't. |
| `ClipIndex.matches` `best` array | every row scoring ≥ `minScore` is appended, then sorted, then `prefix(topK)` | confirmed unbounded-ish; ~40 B/tuple so 800k ≈ 32 MB worst case. A bounded top-K heap is the correct shape. |
| `SearchFacets.refresh` years query | `SELECT DISTINCT strftime('%Y', capture_date, …)` — full `photo_meta` scan, cannot use `photo_meta_capture_idx` | confirmed. `v14`'s own comment says materialize rather than `strftime` at query time; this query breaks that rule. |
| `SearchFacets.refresh` cameras query | `GROUP BY camera_model` cannot use `photo_meta_camera_idx (camera_make, camera_model)` | confirmed, minor |
| `IntentBackfill` | one write **transaction** per candidate file | confirmed |
| `PhotoHeaderBackfill.work` | one `queue.read` per candidate to re-read `content_hash` (5,000 round trips on the serial queue per launch) | confirmed |
| `BurstClusterer` | O(k²) inside a session, `maxSessionSize` 256, recursive largest-gap split | **clean** — the bound is real and the tie-break rule is correct |
| `AutoStacker` / `StackStore.claimedFileIDs` | loads all `stack_members.file_id` into a `Set` | inferred acceptable (ids only) |
| `Database.backfillBasenameFTS` | pre-fetches the covered set to avoid an O(n²) correlated `NOT EXISTS` | **clean, already fixed** |
| migrations v13–v23 | all `CREATE TABLE` / `ALTER TABLE` / `CREATE INDEX`; **zero data rewrites, zero row loops** | **clean — launch cost is O(1)** |

---

### A5. Image decode sites

| Site | Automatic? | `withinDecodeBudget`? |
|---|---|---|
| `ThumbnailCache.imageIOThumbnail(url:)` (grid, prewarm) | **yes** | ✅ line 521, **before** the `EditRenderer.render` branch |
| `ThumbnailCache.imageIOThumbnail(data:)` (audio art) | yes | ✅ 552 |
| `ThumbnailCache.pixelCount` header probe | yes | header-only |
| `VisionServices.boundedDecode` (analyze + `DeepAnalysisBackfill`) | **yes** | ✅ 166 |
| `PaletteExtractor.downsampledRGB` | yes | ✅ 84 |
| `HeroPalette` | yes | ✅ 55 |
| `HeroStage` mid-res (1600) and sharp rungs | user-initiated | ✅ 472 / 505, before the `EditRenderer.render` branch |
| `CollectionPDFExporter` (both paths) | user-initiated | ✅ 208 / 259 |
| `SocialRender` | user-initiated | ✅ 83 |
| `SocialExportCard` preview | user-initiated | ✅ 476 |
| `ImageMetadataStripper` | user-initiated | ✅ 135 |
| `EmbeddedPreview` | user-initiated | ✅ 27 |
| **`EditRenderer.decode` → `CIImage(contentsOf:)`** | user-initiated (editor, Looks browser, Edit-a-Copy, export) | ❌ **none** |
| **`RawSource.decode` → `CIRAWFilter`** | user-initiated | ❌ **none**, and **`scaleFactor` is never set** |
| `MetadataImportModel:309` `CIRAWFilter` | user-initiated (import) | ❌ none |

**The decode-budget rule as written covers automatic (no-click) sites, and every
automatic site is guarded.** The two unguarded renderer paths are reached only
after a click. They are still a real problem, but for cost, not for the bomb
rule — see A11 F3.

---

### A6. Network

| Site | Gated by | Sends |
|---|---|---|
| `Sparkle` (`UpdaterController`) | automatic background check, off-able | appcast GET; EdDSA-verified download |
| `AnnouncementStore.fetchIfNeeded` | launch, off-able in Settings (disables the fetch itself); `URLSessionConfiguration.ephemeral` | GET of a static `announcements.json`; no body |
| `GoogleOAuth` (`:42` revoke, `:153` token) | explicit sign-in / sign-out | PKCE code exchange; no client secret |
| `DriveClient` (8 call sites) | Publish / Manage / portfolio update / launch expiry sweep | the user's own images (rendered → metadata-stripped → verified) + manifest JSON, to the user's own Drive |
| `ClipModelStore.runDownload` | **explicit user action only** — `download()` is called from the Settings/offer UI, never at launch | GET of `manifest.json` + chunks; SHA-256 verified before unpack; fail-closed with `cleanupPartial()` at every step |

Matches DECISIONS' Current-state list (Sparkle, Drive, announcements,
search-model download). **No unsanctioned egress found.** One documentation
defect: `Muse.entitlements`' comment on `network.client` still says "exactly two
sanctioned paths" — now four (A11 F9).

---

### A7. Identity rewrites — do they carry tags, notes AND edits?

| Path | tags | notes | edits + versions | ratings collapse | manual collection membership |
|---|---|---|---|---|---|
| `Indexer.reconcile` hash-collision, **sole** alive path (`:198–206`) | ✅ `unionTags` | ✅ `carryAll` | ✅ `carryAll` | ✅ inside `unionTags` | ✅ |
| `Indexer.reconcile` hash-collision, **shared** row (`:210–217`) | ✅ scoped `unionTags` | ✅ `carry` | ✅ `carry` | ✅ | ✅ |
| `Indexer.reconcile` **split** branch (`:291–314`) | ✅ copy-or-move by same-dir-sibling rule | ✅ `carry` | ✅ `carry` | ✅ (via tags) | ✅ |
| `FileMoveMigration.apply` | ✅ `migrateTags` | ✅ `carry` | ✅ `carry` | ✅ `collapseRatings` | n/a (file_id unchanged) |
| `FolderRenameMigration.apply` | ✅ pre-clear + prefix `UPDATE` | ✅ pre-clear + prefix | ✅ `rewriteParentDirPrefix` (both tables, same pre-clear) | n/a | n/a |

**All five seams carry all three.** This is the best-executed part of the branch.

One gap, **confirmed**: `EditStore.rebuildIndex()` is called from
`MuseApp.swift:126` and nowhere else. Its own doc-comment says it is for
"launch, **and after anything that rewrites paths wholesale (a move or a folder
rename)**". `FolderRenameMigration`/`FileMoveMigration` rewrite `parent_dir` and
`absolute_path`, but `EditStackIndex` is keyed by **path** — so after an in-app
folder rename or file move, every edited file under it renders **unedited**
(grid tile, hero, export, share) until the next launch. See A11 F2.

---

### A8. `AppState` surface — the five added `@Published`

| Property | Spec | Type | What re-evaluates when it fires |
|---|---|---|---|
| `cullResolveShown` | 03 | `Bool` | everything observing `AppState` (one `ObservableObject`); fires on cull-resolve open/close |
| `clipOfferShown` | 03 | `Bool` | same; fires at most once ever (`clipOfferSeenKey`) |
| `editPromptRequest` | 04 | `EditNamePrompt?` | same; fires on version-name prompt open/close |
| `openWithForkRequest` | 04 | `OpenWithForkRequest?` | same; fires on Open-With of an edited file |
| `socialExportRequest` | 07 | `SocialExportRequest?` | same; fires on social-export card open/close |
| (`metadataImportRequest` → `importModal`) | 06 | rename | net zero — DECISIONS records Spec 06 deliberately holding the line |

All five are **modal-presentation flags**, matching the app's existing single
modal seam (`settingsShown`, `driveSharesShown`, `collectionDeleteRequest`, …)
which `ModalChrome` and `EscapeAction` both key off. Moving them to per-feature
stores would fork the Escape-ordering and modal-presentation logic that
`EscapeAction` centralises. Each fires only on present/dismiss.

**My call: these five conform to the foundation's intent and should stay.** The
rule's purpose is to stop features growing `AppState` into their data model;
five booleans routed through the existing modal seam is not that. The +110 LOC
is the same story — it is the modal plumbing and the menu commands for those
five. I am recording this rather than "fixing" it, per the prompt's
evidence-not-permission bar. What is *worth* fixing is that the branch left the
budget with **zero headroom** (75 vs a ~70 target) — noted for the next spec.

---

### A9. Thumbnail cache

| Call site | Requested size | In `renderedVariants`? |
|---|---|---|
| `GridView:1118` | 320×320 @2 | ✅ |
| `HeroStage:380/391/438` | 320×320 @2 | ✅ |
| `HeroStage:392` | 160×160 @2 | ✅ |
| `DuplicatesView:408` | `duplicateTileSize` (140) @2 | ✅ (constant lives on `ThumbnailCache`) |
| `PlacesPage:166` (**Spec 02, new**) | 320×320 @2 | ✅ |
| `CollectionsRow:444` | 320×320 @2 | ✅ |
| `PerfBaseline:124` | `thumbnailProbeSize` | ✅ (asserted in the file's own comment) |
| hero undecodable fallback | quantized to `heroFallbackSizes` ladder | ✅ |
| `ComparePane` (**Spec 03, new**) | deliberately **not** `ThumbnailCache` — direct bounded decode, documented at `:116` | ✅ by exclusion |
| `LooksBrowserView` (**Spec 05, new**) | per-draft ephemera, never `ThumbnailCache` | ✅ by exclusion |
| `SocialExportCard` (**Spec 07, new**) | own decode, documented at `:358` | ✅ by exclusion |

`invalidate(_:)` clears **both stack states** (`currentStackHash` and `nil`,
`:215–226`) across all 7 variants, plus `ImageHeaderSizeCache`. The unedited key
is byte-identical to the pre-Spec-04 key (`:374`, no trailing separator), so no
existing library re-keys on upgrade. **Sweep 9 is clean.**

---

### A10. Error and cancellation paths — what is left behind

| Path | On throw / cancel | Left behind |
|---|---|---|
| `DriveShareService.run` (publish) | `cleanupFolder(folderID)` in a fresh non-cancelled `Task` | **the `OutputRender` temp files** — one per uploaded image, never deleted |
| `runPortfolio` | same | same |
| `runPortfolioUpdate` | `rollback(imageIDs)` before the manifest swap; per-file sweep failures non-fatal and retried next update | same; live manifest untouched until the atomic swap — **correct** |
| `OutputRender.forOutput` (all 6 call sites) | — | **a full-resolution rendered temp per edited file, deleted only by the ≥24 h launch sweep.** A 1,000-image edited publish leaves 1,000 full-res JPEGs in `tmp` |
| `ClipModelStore.runDownload` | `cleanupPartial()` at every failure step, including a failed post-install load-test | nothing; but the **whole model is assembled in RAM** (`var assembled = Data()`) before being written to disk and unzipped |
| `ClipModelStore` cancel mid-chunk | `guard !Task.isCancelled else { return }` returns **without** `cleanupPartial()` and leaves `state == .downloading` | only reachable via `cancelDownload()`/`remove()`, which both clean up and reset state afterwards — **benign** |
| `EditCopyFlow.run` | temp removed on render failure and on move failure | `EditCopyMetadata`'s own temp leaks if `replaceItemAt` fails (`try?`) — 1 file, tmp |
| `EditRenderer.exportFile` | throws before `write` | nothing |
| `WorkThrottleStore.waitUntilRunnable` | a cancelled task parked in `waiters` is never resumed while paused | the `Task` leaks until the pause lifts or the app exits — benign, no state to unwind |
| backfill `Task.isCancelled` checks | `PhotoHeaderBackfill`/`GeocodeBackfill` check per chunk; `DeepAnalysisBackfill` **does not check at all** | in-flight decodes/Vision run to completion |

---

## A11. Ranked findings out of Pass A

Confirmed unless marked. These reorder the Pass B slices: **6 (migrations) is
cheap and clean and drops to last; a new slice 0 "launch & background
scheduling" comes first**, because F1/F4/F5 are the decided-criteria violations
and they touch files three other slices also touch.

| # | Finding | Severity | Status |
|---|---|---|---|
| **F1** | Five uncoordinated launch passes (A1 #6,8,9,10,11) start together, contend for the one GRDB serial queue, and `PhotoTraits.currentVersion = 2` makes #10 re-Vision the entire library at 5,000/launch. Violates foundation §9 "photos browsable immediately, cold start budgeted". | high | confirmed |
| **F2** | `EditStore.rebuildIndex()` is never called after `FolderRenameMigration` or `FileMoveMigration`. `EditStackIndex` is path-keyed, so every edited file under a renamed folder or moved file renders **unedited** everywhere until relaunch. | high | confirmed |
| **F3** | `RawSource.decode` never sets `CIRAWFilter.scaleFactor`, and `EditRenderer.decode` bounds a non-RAW source with a `CIImage` scale transform rather than a bounded ImageIO decode. Editor preview therefore demosaics/decodes at full resolution on every slider tick. Contradicts the DECIDED "edit preview renders at screen resolution, never full-res" and the budgeted slider-to-render metric. | high | confirmed (that `scaleFactor` is unset); the CI-lazy-decode half is **inferred** and needs an instrumented check |
| **F4** | The three backfills honour `WorkThrottleStore`'s **pause** gate but ignore `currentConcurrency`. On battery / Low Power Mode `AnalyzePipeline` narrows to 1 while `DeepAnalysisBackfill` still runs 2 concurrent Vision+CLIP passes and `PhotoHeaderBackfill` 4 concurrent reads. Foundation §9 says throttled on battery/LPM. | high | confirmed |
| **F5** | `DeepAnalysisBackfill` consults the throttle only after accumulating 200 results, and never checks `Task.isCancelled`. Pressing Pause burns ~200 more Vision+CLIP scans before it takes effect. | med | confirmed |
| **F6** | `EditStore.warmIndex` → `EditStackIndex.merge` → `canRender` → `LutRegistry.rgbaCube` performs a **synchronous multi-MB DB read on `@MainActor`**, against both functions' own written warnings. Fires on every 400 ms autosave. | high | confirmed |
| **F7** | Every autosave runs two **full-table joins** (`allWithAlivePaths` unfiltered then Swift-filtered; `versionCounts` over all `edit_versions`). O(library edits) per slider settle. | med | confirmed |
| **F8** | `ClipIndex.matches` uses `LIMIT/OFFSET` paging → O(n²/chunk) row-visits; and accumulates every above-threshold match before truncating to `topK`. | med | confirmed |
| **F9** | `OutputRender` temps are never deleted by their consumers; only the ≥24 h launch sweep collects them. A large edited Drive publish leaves ~1 full-res render per image in `tmp`. | med | confirmed |
| **F10** | `GeocodeBackfill` has **no per-launch cap** and is reachable twice concurrently (launch `Task` + chained from `PhotoHeaderBackfill`), each loading the 7 MB dataset and building its own k-d tree. `IntentBackfill` has no cap and writes one transaction per file. | med | confirmed |
| **F11** | `ClipModelStore` assembles the whole model archive in RAM (`var assembled: Data`) before writing it out — against "never write code that assumes everything fits in RAM". Also `unzip` via `Process`/`/usr/bin/unzip` from a sandboxed app is unverified at runtime. | med | confirmed (RAM); **unverified** (sandbox exec) |
| **F12** | `SearchFacets.refresh` runs an unindexable `strftime` full scan of `photo_meta`, and is invoked by three concurrent launch backfills plus every analyze pass and every import. `v14`'s own comment forbids exactly this pattern. | low | confirmed |
| **F13** | `Muse.entitlements` comment says `network.client` has "exactly two sanctioned paths"; there are now four. `CLAUDE.md`'s network-policy paragraph has the same drift. | low (doc) | confirmed |
| **F14** | `OutputRender.renderedImage(url:maxPixel:)` has no call sites. | low | confirmed |
| **F15** | `PhotoHeaderBackfill` issues one extra `queue.read` per candidate (5,000 serial-queue round trips per launch) to re-read a hash it could batch. | low | confirmed |

### Not findings — checked and clean

- All five identity-rewrite seams carry tags **and** notes **and** edits (A7).
- Every **automatic** decode site is `withinDecodeBudget`-guarded (A5).
- Thumbnail keying, both-stack-state invalidation, and the unedited-key
  byte-compatibility rule (A9).
- Migrations v13–v23 are schema-only, O(1) at launch (A4).
- No unsanctioned network egress (A6).
- No new `withAnimation`-around-`AppState`-write, no per-keystroke DB work, no
  uncapped debounce (A3).
- `BurstClusterer`'s n² bound is real and its tie-break is correct (A4).
- The `AppState` freeze breach is 5 properties, not 23, and all five are modal
  flags on the existing modal seam (A0, A8).

---

## Pass B — slice results

### Slice 0 — launch & background scheduling (F1, F4, F5, F10, F12, F15) — DONE

Authority: foundation §9 ("analysis is background, throttled, pausable, photos
browsable immediately, cold start budgeted"), §13 #22 (analysis always on —
scheduling only, never an off switch) and #25 (never assume RAM-residency).

| Finding | Fix | Where |
|---|---|---|
| F1 | The four launch backfills are ONE serial chain (`LaunchBackfills.run`), at `.utility`, started after the edit-index warm-up rather than alongside it. Order: intent → header → geocode → deep analysis (cheap → expensive, dependency-first). Nothing else changed about what they do. | `Intelligence/LaunchBackfills.swift` (new), `MuseApp.swift` |
| F4 | `ThrottlePolicy.scaled(_:normal:)` + `WorkThrottleStore.concurrency(normal:)`: a pass with its own full-speed width narrows to 1 on battery/LPM and 0 on pause, instead of honouring only the pause gate. Used by both concurrent passes. | `ThrottlePolicy.swift`, `WorkThrottleStore.swift`, both backfills |
| F5 | `DeepAnalysisBackfill` now consults the throttle and `Task.isCancelled` **per spawn** instead of per 200-row write chunk, and re-reads its width per spawn. In-flight scans still finish (pause stays resumable — same rule as `AnalyzePipeline`). | `DeepAnalysisBackfill.swift` |
| F10 | `BackfillCoordinator` — single-flight with one trailing re-run, keyed per pass; geocode, deep-analysis, header and intent all route through it, so the launch copy and the import/model-install copy can no longer overlap. `GeocodeBackfill` is now keyset-paged (`ORDER BY f.id`, `id > ?`) instead of fetching every candidate into RAM, with a cheap first page probed before the 7 MB dataset is parsed. `IntentBackfill` gained a 5,000/launch cap and writes one transaction per 200 files instead of one per file. | `LaunchBackfills.swift`, `GeocodeBackfill.swift`, `IntentBackfill.swift` |
| F12 | The years facet is a **loose index scan** (recursive `MIN(capture_date)` seeks on `photo_meta_capture_idx`) instead of `SELECT DISTINCT strftime(...)` over all of `photo_meta` — exact answer, O(distinct years · log n). `SearchFacets.refresh()` is single-flight with a trailing re-run, so three concurrent callers no longer run three identical sweeps. | `SearchFacets.swift` |
| F15 | `PhotoHeaderBackfill` reads the chunk's hashes in ONE query instead of one `queue.read` per candidate (5,000 serial-queue round trips per launch). | `PhotoHeaderBackfill.swift` |

Two further defects of the same class, found in round 2 and **confirmed** by
reading the code, fixed here rather than deferred:

- `DeepAnalysisBackfill`'s context fetch ran one `Row.fetchOne` per candidate
  inside a single `queue.read`. A GRDB `DatabaseQueue` is one serial
  connection, so 5,000 statements in one read hold the queue — and every
  interactive fetch behind it. Now 500 ids per query.
- `IntentBackfill` built its candidate list with two queries **per file** and
  held every candidate's full OCR text in RAM. Now two queries per 200-file
  chunk, ids-only up front.

**Residual, recorded not fixed:** `files_fts` declares `file_id UNINDEXED`, so
any `WHERE file_id = ?` against it is a full FTS scan. The chunking above cuts
IntentBackfill's cost by ~200×, but the shape is inherent to the v1 schema and
fixing it properly means rebuilding the FTS table in a migration — out of
proportion to a capped one-time pass. Also observed: `AnalysisStatusStore.refresh`
runs two `COUNT(*) … EXISTS` scans of `files`, rate-limited to one per 5 s and
off-main; fine at the design centre, a graceful-degradation cost at 800k.

Tests: +9 (`ThrottlePolicy.scaled` table, `BackfillCoordinator` single-flight and
key independence, distinct-years exactness incl. gap years and NULLs, geocode
keyset advance / already-geocoded skip / dataset-version bump).
Suite after this slice: **1,757 tests, 0 failures**.

### Slice 1 — invariants (+ F2, F9, F14) — DONE

| Finding | Fix |
|---|---|
| F2 | `EditStore.rebuildIndex()` is now called after all three path-rewriting migrations — `moveFiles`, file rename, folder rename. `EditStackIndex` is path-keyed, so without it every edited file under a renamed folder rendered UNEDITED everywhere until relaunch. Its own doc-comment already prescribed this; nothing called it. |
| F9 | `OutputRender.discard(_:)` — collects a rendered temp and its per-render directory as soon as the consumer is done. Wired into all three Drive upload loops, `SocialRender.export` and the PDF exporter. The PDF exporter also now renders **inside** each task instead of mapping all N up front, so an N-image edited export no longer puts N full-resolution temps on disk at once. `discard` is a deliberate NO-OP for an unrendered output (that URL is the user's own file) — two independent guards, both tested. The two share-sheet paths keep relying on the launch sweep, documented at both call sites: `NSSharingServicePicker` reads its files lazily after the user picks a service. The launch sweep itself moved off the main thread. |
| F14 | `OutputRender.renderedImage(url:maxPixel:)` deleted — no call sites, and it duplicated the render decision outside the `RenderedOutput` choke point without a decode-budget guard. |

Three further defects, all **confirmed** by reading the code:

- **F16 (high) — Escape did nothing for five of the new modals.** Specs 03/04/07
  added `cullResolveShown`, `clipOfferShown`, `editPromptRequest`,
  `openWithForkRequest` and `socialExportRequest` to `AppState.modalPresented`
  but gave none of them a branch in `ContentView.dismissTopModal()`.
  `modalPresented` also gates the grid key catcher, so while any of those cards
  was open Escape *and* the arrow keys were dead. All five now peel, in the
  card-class order the rest of the list uses.
- **F17 (med) — the one-time search-model offer re-offered forever.** Its
  "Not Now"/"Download" dismissal wrote `clipOfferShown = false` directly, and
  `museModal`'s `onDismiss` (which records `clipOfferSeenKey`) fires only on a
  scrim click. Both routes now go through one `dismissClipOffer()`.
- **F18 (high) — compare panes and the social-export crop stage previewed the
  UNEDITED original.** DECISIONS' Spec-04 forward note says in as many words
  that compare panes MUST join the edit-render sweep; they didn't. For the
  social crop stage it was worse than cosmetic: the export ships edited pixels
  through `OutputRender`, so with a crop or straighten in the stack the user
  positioned the crop against a differently-framed picture and `decodedSize`
  fed the crop math the wrong geometry. Both now render the stack, budget-gated,
  with the same branch `HeroStage` uses.

Checked and clean: all three Drive upload paths (publish, portfolio, portfolio
update) go through `OutputRender` → `ImageMetadataStripper.strip`, fail-closed;
`uploadManifest` takes `Data` and pins its own mime, so it structurally cannot
be an image path; rating writes from both importers go through
`TagStore.setRating`, the single exclusivity seam; `EffectiveDimensions` has
consumers in grid, hero, aspect cache and the Info card; `modalPresented` and
`dismissTopModal` now agree entry-for-entry.

Suite after this slice: **1,759 tests, 2 skipped, 0 failures.**

---

## Resume here — next session

Pass A is complete and committed. Pass B has not started; no code has been
changed by this review.

Paste this into a clean chat:

> Continue the Specs 01–07 review of `new-product-build-1`, and **run it to
> completion — every remaining slice, then Pass C, then the final pass. Do not
> stop between slices, do not report progress back, and do not ask me to
> confirm anything.** The brief and the plan docs were written so you don't have
> to. Surface ONCE at the very end, short.
>
> Read `docs/new-build/REVIEW-PROMPT.md` first — it is the binding brief and all
> its constraints still apply (work SOLO: no subagents, no Workflow, no fan-out;
> find problems by reading code; verify every finding in the code and say plainly
> whether you confirmed or inferred it; loop each slice until green, cap 5 rounds;
> commit each slice as you finish it).
>
> Pass A is DONE. Its output — the ten sweep tables and 15 ranked findings — is
> `docs/new-build/REVIEW-FINDINGS.md`. Read it before touching anything; do not
> redo Pass A.
>
> Pass A reordered the slices. Work them in THIS order, back to back:
>
> 0. **Launch & background scheduling** (new — goes first because its findings are
>    decided-criteria violations in files that slices 2, 5 and 7 also touch):
>    **F1, F4, F5, F10, F12, F15**.
> 1. Invariants — the original slice 1, plus **F2** (`EditStackIndex` not rebuilt
>    after a folder rename or file move) and **F9**, **F14**.
> 2. Editing engine + readouts (04, 05) — plus **F3, F6, F7**.
> 3. Import (06).
> 4. Sharing and social export (07) — plus **F13**.
> 5. CLIP, culling, search (02, 03) — plus **F8, F11**.
> 6. Cross-spec seams.
> 7. Migrations v13–v23 — demoted to last; Pass A found them schema-only and O(1),
>    so this is a confirmation pass, not an investigation.
>
> **Resolve every behavioural question from the docs, never from me.**
> `muse-photo-foundation.md` §9 and §13 are the authority, with
> `docs/new-build/DECISIONS.md` (Current state block first) for build-level
> specifics and `docs/durable-constraints.md` for must-not-break rules. Decide,
> act, and record the reasoning in REVIEW-FINDINGS.md and the commit message. If
> genuinely nothing answers it, make the call yourself from the foundation's
> stated intent and write down what you concluded and why — don't wait on me.
>
> Green for a slice means all of: clean build with a verified-fresh binary
> (`stat` its mtime — an incremental build prints BUILD SUCCEEDED over a stale
> `.app`); the FULL suite passes — **1,748 tests, 2 skipped, 0 failures** is the
> verified baseline, and do NOT pipe `xcodebuild` through `tail`; and a fresh
> re-review surfaces no new confirmed findings two rounds running.
>
> At the very end: re-run the suite, re-verify the Pass A tables, update
> `CLAUDE.md` / `DECISIONS.md` Current state / `docs/architecture-map.md` /
> `docs/session-log.md` per the brief's final pass, commit, and give me ONE
> summary — what changed, what you left and why, what you couldn't verify.

### Two open questions to carry forward

- **F3's non-RAW half is INFERRED, not confirmed.** Whether
  `CIImage(contentsOf:)` followed by a scale transform actually forces a
  full-resolution decode is a Core Image internal. Instrument it in Pass C;
  do not "fix" it by reasoning. The RAW half (`CIRAWFilter.scaleFactor` never
  set) IS confirmed by reading the code.
- **F11's sandbox question is UNVERIFIED.** `ClipModelStore.unzip` shells out to
  `/usr/bin/unzip` via `Process` from a sandboxed app. If the sandbox denies the
  exec, the CLIP model can never install at all and every Spec 03 semantic-search
  feature is dead on arrival behind a fail-closed error message. This needs a
  runtime check before any effort goes into tuning that path.
