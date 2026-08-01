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

### Slice 2 — editing engine + readouts (04, 05) (+ F3, F6, F7) — DONE

| Finding | Fix |
|---|---|
| F3 (RAW half — the confirmed one) | `RawSource.decode` takes a `maxPixel` and sets `CIRAWFilter.scaleFactor` from `nativeSize` BEFORE reading `outputImage`. Every proxy render — i.e. every slider tick — was demosaicing the full 24–60 MP frame and then throwing most of it away in a downstream `CIImage` scale transform. Exports still pass `maxPixel: 0` and demosaic at full size. This is the "edit preview renders at screen resolution, never full-res" budget (foundation §9). |
| F6 | `EditStore.rebuildIndex`/`warmIndex` build the index inside `Task.detached` instead of on `@MainActor`. Building an entry decodes each stack's JSON and, for a LUT-bearing stack, does a synchronous multi-MB `queue.read` in `EditRenderer.canRender` → `LutRegistry.rgbaCube` — both headers say those must never run on the main thread, and `warmIndex` runs on every 400 ms autosave. The index is lock-guarded, so writing it off-main is safe. |
| F7 | `EditRecordStore.withAlivePaths(_:db:)` and `versionCounts(forPaths:db:)` — chunked `IN (…)` variants of the two full-table joins. `warmIndex` no longer loads every edit in the library and filters in Swift, and the per-save version-count refresh is scoped to the saved paths (a missing count removes the key, which is what drops the badge when the last version goes). The unscoped versions remain for launch and wholesale path rewrites. |

Also fixed: `EditCopyMetadata.copyMetadata` swallowed a `replaceItemAt` failure
with `try?`, stranding its temp; it now cleans up and throws (the caller
already treats metadata carry as best-effort, so an Edit-a-Copy still lands).

Checked and clean: `EditStackCodec` canonical `.sortedKeys` encoding over the
NORMALIZED stack with the hash pinned by a literal fixture; the autosave/history
split (`commitGesture` is the single push site, on gesture end); `RenderCoalescer`
latest-wins with one render in flight; the stats tap piggybacked on the completed
render at 256 px and gated on `statsVisible`; the Looks browser's single decode
reused across every preset and LUT cell, off-main and cancellable;
`EditCopyFlow`'s render → metadata → move → index ordering, temp-first at every
step.

**Observation, not acted on:** the stats tap calls
`EditRenderer.toneStageImage`, which re-decodes the file a second time per
render (at 256 px). With the RAW fix above that decode is now genuinely small;
reusing the canvas render's decoded source instead would mean caching it on the
session. Left for the Pass C slider-to-render measurement to judge.

Suite after this slice: **1,763 tests, 2 skipped, 0 failures.**

---

### Slice 3 — import (06) — DONE

**The claim verifies literally.** Every DB write in `Import/` goes through
`ImportSupplement` (the one writer for external GPS + capture date),
`MetadataImportApply` (insert-or-promote keywords, scope resolution),
`NoteStore`, `TagStore.setRating` or `EditStore.save`. No importer writes
`files`, `photo_meta`, `tags` or `edits` itself. Re-run idempotency holds at
every leg: keywords insert-or-promote, notes fill gaps only, ratings are gated
on `hasRating`, Lightroom edits are skipped when a stack already exists (the
stack written last run IS that stack), and Apple Photos albums reuse an
existing collection by name. Cancellation is checked per file in all five
models.

Two findings, both **confirmed**:

- **F19 (high, whole-app) — the database ran in rollback-journal mode with
  `synchronous = FULL`.** `Configuration` set only `foreignKeysEnabled`, so
  every write transaction was a journal create + fsync + delete — and this app
  commits in small transactions constantly (per index batch, per analyzed file,
  per tag edit, per backfill chunk, and once per file during an import, which
  is unavoidable since each file's write depends on its own header read). Now
  `journal_mode = WAL` + `synchronous = NORMAL` via `prepareDatabase`. Durability:
  NORMAL can cost the last few committed transactions on power loss but cannot
  corrupt the file, and what those carry is derived metadata the next
  analyze/index pass regenerates — the library's truth is the files on disk.
  Verified safe on the two things that could have made it wrong: nothing else
  in the tree opens `muse.sqlite` (backup builds its own archive by content
  hash), and the share extension does not touch the database. **This changes a
  persistent file-header setting on every existing library** — flagged loudly
  here and in the durable constraints.
- **F20 (med, security/resource) — five unbounded `Data(contentsOf:)` reads of
  user-chosen metadata files** (XMP sidecar ×1, `.xmp` preset, Takeout JSON,
  Eagle `metadata.json` ×2). A sidecar is kilobytes by nature, but the file is
  arbitrary user input and an import walks thousands of them. Now one
  `BoundedRead.metadata(at:limit:)` helper, 16 MB cap, skip-never-truncate —
  the import-side twin of `withinDecodeBudget`, and the same rule as DECIDED #25.

Also checked: XMP is parsed by `CGImageMetadataCreateFromXMPData`, Apple's own
constrained-RDF parser, not a raw `XMLParser` — no external-entity surface to
close.

Suite after this slice: **1,767 tests, 2 skipped, 0 failures.**

---

### Slice 4 — sharing & social export (07) (+ F13) — DONE

One finding, **confirmed**:

- **F21 (med, security) — the portfolio manifest fetch was bounded only AFTER
  the body was buffered.** `acceptFetchedManifest` capped `text.length`, but the
  caller had already done `await resp.text()` on a response whose Drive file id
  comes from the **unsigned URL fragment** — so anyone handing a victim a link
  chooses which anyone-readable Drive file that is, including a multi-gigabyte
  one. Now `readCapped(resp, limit)`: honours a declared `Content-Length` before
  reading anything, and otherwise reads through the stream reader and
  `cancel()`s the moment the cap is passed. The post-hoc cap stays as a second
  gate. +3 page tests (small body, over-declared length, undeclared oversized
  stream).
- **F13 (doc)** — `Muse.entitlements`' `network.client` comment and CLAUDE.md's
  network-policy paragraph both said "two sanctioned paths"; there are four
  (Sparkle, Drive, `announcements.json`, the on-demand model download). Both
  now enumerate all four and note that the recipient browser's portfolio
  `manifest.json` fetch is page traffic, not an app path.

Checked and clean: the page's CSP (`default-src 'none'`, no inline anything)
plus `_headers` (`frame-ancestors 'none'`, `X-Frame-Options: DENY`, nosniff,
`Referrer-Policy: no-referrer`, HSTS); `MAX_INFLATED` zip-bomb cap; the 1000-image
grid cap, `VALID_ID` length bound and per-field caps; `sanitizeText` over every
attacker-suppliable display string, with `textContent` never `innerHTML`;
`isExpired`'s strict date-only requirement and its deliberate portfolio branch;
`DriveSharePublishGuard` mirroring the page's own validator, so the app cannot
mint a link its page would reject (filenames are bounded by the filesystem's own
255-byte component limit, well under `MAX_NAME`); the portfolio update's
upload → atomic manifest swap → sweep ordering with rollback before the swap;
the X ladder driving quality off X's own byte invariants and failing the FILE
rather than shipping a recompressible one; and `ImageMetadataStripper`'s
verify-or-throw with a decode-budget guard before the re-encode.

Suite after this slice: **1,767 tests, 2 skipped, 0 failures**; share page: all
tests pass.

---

### Slice 5 — CLIP, culling, search (02, 03) (+ F8, F11) — DONE

| Finding | Fix |
|---|---|
| F8 | `ClipIndex.matches` pages by KEYSET (`file_id > ?`) instead of `LIMIT/OFFSET` — SQLite had to walk and discard `offset` rows per page, ~78M discarded row-visits for an 800k library, quadratic in the one file whose header promises graceful degradation. The accumulator is also bounded now: candidates are trimmed back to `topK` whenever they pass `trimAt` (= 2·topK), with the weakest surviving score becoming the running threshold (`>=`, so ties still enter). +2 tests: exact top-K equality against a brute-force reference with more candidates than `trimAt`, and a best-match row placed LAST in id order past the first chunk — which only a cursor that actually advances can find. |
| F11 (RAM half) | The model archive streams to disk and is hashed incrementally (`SHA256` updated per chunk, `ClipModelManifest.verify(digest:)`) instead of being assembled in a `Data` — a few hundred MB held in RAM on the 8 GB reference machine, and then written out anyway. Cancellation mid-stream leaves state to `cancelDownload()`/`remove()`, as before. |
| F11 (sandbox half) | **Still UNVERIFIED and deliberately untouched** — `unzip` shells out to `/usr/bin/unzip` via `Process`. Pass A's instruction was to check this at runtime before spending effort on it; that check is Pass C's. If the sandbox denies the exec, the fix is a built-in ZIP reader (a dependency is not an option — DECIDED #26 keeps dependencies minimal). |

One more, **confirmed**, same class as F8:

- **F22 (low/med) — `RediscoveryQueries.shuffle` materialized every alive photo
  id** to pick 500 of them (~50 MB of strings at the 800k tier). It is now a
  seeded reservoir sample (Algorithm R) over a cursor: O(limit) memory, one
  indexed pass, same seed → same set. +1 test that the sample actually reaches
  the tail of the library rather than a prefix.

Checked and clean: `ClipModelStore`'s fail-closed ladder (manifest cap → chunk
stream → SHA-256 → unpack → load-test → `.verified` marker, `cleanupPartial()`
at every failure); the CLIP generation and vector-length guards that stop
cross-model pairing; trait/embedding markers including the deliberate
NULL-vector attempted-marker; ephemeral cull state with no persistence surface;
`is:`/`faces:`/`pets:` reading no tags; offline geocoding with no per-photo
network.

**Observation, not acted on:** `RediscoveryQueries.onThisDay`'s FALLBACK query
(for files with no `photo_meta` row) filters on `strftime` over
`files.created_at` and cannot use an index — a full scan of `files` per
activation. It is user-initiated, off-main, and the comment is right that the
set shrinks toward zero as the header backfill completes; fixing it properly
means materializing a month-day column for `created_at`, i.e. a migration, which
is out of proportion.

Suite after this slice: **1,770 tests, 2 skipped, 0 failures.**

---

### Slice 6 — cross-spec seams — DONE

This slice's whole class had already produced three findings in earlier slices
(**F16** modal peel, **F18** the edit-render sweep, and slice 0's four
uncoordinated launch passes) — each one a case of "two specs edited the same
seam and neither knew". One more of exactly that shape:

- **F23 (med) — the grid's cull badge was never built.** DECISIONS (Spec 03,
  "Ephemeral cull state") specifies a **bottom-leading** tile badge while a
  session is active; `GridView` has no such badge and never reads
  `CullStore.mark`. The grid's key catcher DOES accept K/X/U, so a user could
  mark files from the grid — the surface a cull pass is actually driven from —
  and see no feedback at all. Spec 04's badge comment even lists
  "bottom-leading cull" among the assigned corners as though it existed. Now
  built: `CullStore` is observed ONCE in `GridView` and the mark is passed down
  like `rating` (a virtualized grid must not mount a store observer per tile),
  the badge is display-only in the free corner, the mark is announced in the
  tile's accessibility value, and a running session exposes named
  Keep/Reject/Clear actions — VoiceOver swallows the K/X/U keys, so without
  them cull marking was mouse-and-keyboard-only.

Checked and clean: `SearchService`'s merge of Spec 02 tokens with Spec 03 CLIP
— folder-grain (`file_id`, `parent_dir`) restrictions survive the semantic leg,
content-derived tiers correctly un-restrict, tokens AND after the relaxation
loop, and the expensive leg is skipped on a superseded pass;
`AnalyzePipeline`'s header/traits/CLIP/sidecar additions; the tile-corner
assignment now genuinely complete (stack · star · cull · edited).

Suite after this slice: **1,770 tests, 2 skipped, 0 failures.**

---

### Slice 7 — migrations v13–v23 — DONE (confirmation pass)

Pass A's reading holds: **every one of v13–v23 is pure DDL** — `CREATE TABLE`,
`ALTER TABLE … ADD COLUMN`, `CREATE INDEX`. No row loops, no data rewrites, so
launch cost is O(1) regardless of library size. (The only data-touching
migrations in the whole chain are the pre-Spec-01 `v9_fts_basename_backfill`
and `v8_collection_sort_order`, both already fixed and both idempotent.)
`v22_photo_stats` ALTERs `photo_traits` rather than creating a table, exactly as
DECISIONS' Current-state block warns; the re-scan it implies is carried by
`DeepAnalysisBackfill`'s standing per-launch cap, which slice 0 also made
serial and throttle-aware.

New: `MigrationChainTests` pins the **chain** rather than any one migration —
the exact registration order (GRDB replays by name, so a rename or reorder
silently changes what an existing library becomes on its next launch), the
endpoint at `v23_edit_luts` (making DECISIONS' "next migration is v24" claim
executable), a fresh-database run that asserts every Spec 01–07 table exists,
and a partial migration that stops at `v12` and then completes — the exact shape
of a real upgrade from a pre-Spec-01 library.

Suite after this slice: **1,774 tests, 2 skipped, 0 failures.**

---

## Pass C — runtime confirmation

Fresh binary verified by `stat` (mtime seconds old, built after deleting the
`.app` from DerivedData), launched with `MUSE_TRACE=1` against the real 46 MB
library.

**The launch trace, after slice 0's fix:**

```
  0.00s  edit-index.start
  0.11s  grid.firstPaint          ← photos browsable immediately (foundation §9)
  4.76s  edit-index.end
  4.77s  intent-backfill.start
 10.52s  analyzePending.call urls=1915
 10.53s  intent-backfill.end
 10.53s  photo-header-backfill.start
 12.87s  photo-header-backfill.end
 12.87s  geocode-backfill.start
 12.88s  geocode-backfill.end     ← drained by the header chain, as predicted
 12.88s  deep-analysis-backfill.start
 94.00s  deep-analysis-backfill.end
```

One pass at a time, in the intended order, behind the edit-index warm-up, with
the 81 seconds of Vision/CLIP work running alone at the end instead of
contending with four other passes and the first folder open. This is Pass A's
table A1 replaced by measurement. Migrations v13→v23 replayed against real data
with no error, and the database converted to WAL on first open.

**The two open questions Pass A left, both settled by measurement:**

- **F11's sandbox half — RESOLVED, it works.** The test host IS the app, signed
  with `com.apple.security.app-sandbox = true`, and it execs `/usr/bin/unzip`
  into its container successfully. `ClipModelStore.unzip` is fine, and
  `SandboxProcessTests` now pins it (with a hand-built stored-entry ZIP, so the
  fixture needs no dependency and no second exec). If it ever fails, the fix is
  a built-in ZIP reader — a dependency is not an option (DECIDED #26).
- **F3's non-RAW half — DISPROVED.** On a 6000×4000 JPEG:
  `EditRenderer.render` at 1024 px = **59 ms**, a bounded ImageIO decode of the
  same file at 1024 px = **70 ms**, `EditRenderer.render` at 4096 px =
  **73 ms**. Cost scales with the REQUESTED size and beats a bounded ImageIO
  decode — not the signature of an unconditional full-resolution decode. Core
  Image fuses the downstream scale into its graph. The inference was wrong and
  the existing non-RAW code stands; the RAW half was real and is fixed. This is
  exactly why Pass A said to instrument it rather than "fix" it by reasoning.

**Also found at runtime:** the app container's `tmp` held ~700 leftover
`<UUID>/x.txt` directories and 169 loose `.cube` files — both from TESTS
(`TrashManagerTests`, `LutStoreTests`) that never cleaned up their fixtures,
one per run for months. Not an app leak; fixed in both tests.

**Not verified at runtime — everything that needs hands on the GUI:** hero
open/close, the editor (sliders, curve, eyedropper, before/after, versions,
presets, Edit-a-Copy), compare and cull, all five import sources, social
export, Drive share and portfolio, and the backup/restore round trip. Static
review and the unit suite cover them; nobody has driven them.

---

## Final pass — Pass A tables re-verified

- **A1 (launch work)** — replaced by the trace above. `MuseApp.task` now fires
  ONE backfill chain; the remaining `Task {}`s are the edit-index warm-up, the
  detached temp sweep, announcements, and the env-gated perf harness.
- **A3 (main-thread work)** — the two confirmed defects are gone: the LUT read
  is off-main (F6), and the launch temp sweep is detached. No new
  `withAnimation`-around-`AppState`-write, no per-keystroke DB work.
- **A4 (algorithmic cost)** — `ClipIndex` is keyset + bounded top-K;
  `SearchFacets`' years query is a loose index scan; `RediscoveryQueries.shuffle`
  is a reservoir sample; the per-file query loops in three backfills are chunked.
- **A5 (decode sites)** — unchanged and still complete; the two new
  edit-render call sites (`ComparePane`, the social crop stage) are both
  budget-gated.
- **A8 (`AppState` surface)** — still 75 `@Published`, 1,512 LOC. This review
  added none; the cull badge is passed down as a parameter and `CullStore` is
  observed once in `GridView`.
- **A10 (error/cancellation)** — the `OutputRender` temp row is closed (F9);
  `EditCopyMetadata`'s temp is cleaned up; `DeepAnalysisBackfill` now checks
  cancellation.

Final suite: **1,775 tests, 2 skipped, 0 failures** (baseline 1,748 + 27 added by this review). Wall time also dropped from ~68s to ~50s, which is the WAL change (F19) showing up in the test suite's own write pattern.

---

---

## Review complete — 2026-08-01

Pass A, all eight Pass B slices, Pass C and the final pass are done and
committed, one commit per slice. Nothing is outstanding from the brief.

**Both of Pass A's carried-forward questions are answered** (see Pass C): F3's
non-RAW half was DISPROVED by measurement and the existing code stands; F11's
sandbox question is RESOLVED — the exec works and a test now pins it.

**What a next session should pick up**, in order:

1. **Drive the GUI.** The whole list under "Not verified at runtime" above.
   That is the only real gap left in this branch's confidence, and it needs
   hands, not another review.
2. **The 146 untranslated French keys** (Specs 03, 06) — known-open, flagged
   not chased, and by CLAUDE.md's own rule those features are unfinished until
   they're done.
3. **Backup carries no edit data** — Spec 09's amendment A2 closes it; still
   open.
4. Two costs recorded but deliberately not fixed, both needing a migration to
   do properly: `files_fts.file_id` is UNINDEXED (lookups by file_id are full
   FTS scans), and `RediscoveryQueries.onThisDay`'s no-`photo_meta` fallback
   filters on `strftime` over `files.created_at`.


---

## Round 2 — 2026-08-01

A second pass, aimed at what this document did **not** cover: whether the
features that already shipped in v1.5 still work now that Specs 01–07 inserted
`EditStackIndex` / `EffectiveDimensions` / `OutputRender` into their code paths
and flipped the database to WAL.

Findings, fixes and the checked-and-clean list live in
**`docs/new-build/FEATURE-LEDGER.md`**, which is also the standing feature ×
verification ledger going forward — read and update that rather than this file.

Four findings (R2-1…R2-4), suite 1,775 → **1,783**. The 146 untranslated French
keys are closed (catalog now 1,002 keys, 0 untranslated). G1 — nobody has driven
the GUI — is unchanged and is the branch's remaining confidence gap.
