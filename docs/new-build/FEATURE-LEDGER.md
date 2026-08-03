# Muse feature ledger

**What this is.** One row per shippable feature area, with an honest verification
state for each. It exists so a review can be *checked against something* rather
than re-derived from scratch, and so "we tested it" never has to mean "someone
remembers testing it".

**How to use it.** Before shipping, read the rows your change touches. After a
review or a runtime pass, update the state columns in the same commit as the
work. A row whose state you did not personally establish stays as it was — do
not upgrade a row on inference.

**Verification states** — deliberately separate, because they fail differently:

| State | Means |
|---|---|
| **A — automated** | Unit tests pin the behaviour. Named test files in the row. |
| **S — static** | Someone read the code against its spec. Date + reviewer pass. |
| **R — runtime** | Someone drove it in the running app and saw the outcome. |

`A` catches regressions, `S` catches design and invariant drift, `R` catches
"it compiles, passes, and does nothing" — which is the failure class this branch
actually produced (the grid cull badge that was specified and never built, the
five modals with no Escape branch). **A + S is not a substitute for R.**

Last full pass: **2026-08-02** (general image export, P29). Suite:
**1,859 unit tests, 2 skipped, 0 failures** — 1,791 before export's 68 — plus
**20 UI tests** that drive the real app
(`MuseSurfaceDriveTests`, `MuseTagChipRowTests`).
*(The previous line here read "1,811 unit tests … plus 20 UI tests". Measured,
1,811 was the TOTAL including those 20 — the unit target alone was 1,791. No
tests were lost; the old figure double-counted.)*
Release build
warning-free and universal (`x86_64 arm64`); `./scripts/audit-invariants.sh`
12/12 green.

---

## Standing gaps (read first)

These are true across many rows and are not repeated in each one.

| # | Gap | Status |
|---|---|---|
| G1 | **Almost nothing on `new-product-build-1` has been driven in the running GUI.** | **PARTIALLY CLOSED 2026-08-01** (round 7) — `MuseSurfaceDriveTests` drives the app via XCUITest and confirms, by screenshot, that the editor, readouts, compare, duplicates, all five import panels, backup and settings all open and respond, and that every modal honours Escape. `MuseExportDriveTests` covers the export card the same way. **2026-08-02:** 12/12 green after the editor-canvas refactor — which is the runtime confirmation of that refactor, side-by-side included. (Six of those tests had been failing on a fixed window fraction, not on app behaviour; see the drive-suite rule in REVIEW-LENSES.) **Still open:** feature *correctness* (no slider moved, no render compared), a full export-to-disk run, social export, Drive publish, restore/delete, and running an import to completion. See the G1 section at the end of this file. |
| ~~G2~~ | ~~Backup does not carry edit data.~~ | **CLOSED 2026-08-01** — Spec 09 amendment A2 implemented: stacks, versions/snapshots, presets and LUT bytes all ride `.muselibrary`, restore-wins at the new `parent_dir`. |
| G3 | `files_fts.file_id` is `UNINDEXED`, so any `WHERE file_id = ?` against it is a full FTS scan. Callers are chunked to make it cheap; fixing it properly means rebuilding the FTS table in a migration. | **ACCEPTED** |
| G4 | `RediscoveryQueries.onThisDay`'s no-`photo_meta` fallback filters on `strftime` over `files.created_at` and cannot use an index. Set shrinks toward zero as the header backfill completes. | **ACCEPTED** |
| G5 | Distribution is still **direct + Sparkle**. The StoreKit plumbing in `Commerce/` is inert scaffolding; the Mac App Store move is deferred (`docs/superpowers/plans/deferred-mac-app-store-migration.md`). | **DEFERRED** |
| ~~G6~~ | ~~Swift 6 strict-concurrency warnings.~~ | **CLOSED 2026-08-01** — the count was **442** (221 unique × 2 arches), not ~60 as first estimated. All eliminated; the Release build is now warning-free. |

**Closed since round 1:** the 146 untranslated French keys (G-loc) — the catalog
is now **1,002 keys, 0 untranslated**. **Closed in round 3:** G2 (backup carries
edit data) and G6 (the concurrency warnings).

**G1 is PARTIALLY CLOSED as of round 7** — the surfaces open and respond, confirmed by screenshot (see the G1 section at the end of this file). What remains is feature *correctness*, plus social export, Drive publish, restore/delete and running an import to completion. **R7-1** (Spec 03 §5 region similarity specified but never built) is the other open item, and it is a product decision rather than a defect.

---

## Part 1 — pre-branch features (Polish 1–28, shipped in v1.5)

These all worked before `new-product-build-1`. The question this branch raises is
whether they *still* work, because Specs 01–07 inserted three new seams
(`EditStackIndex`, `EffectiveDimensions`, `OutputRender`) into their code paths
and changed a database-wide setting (WAL). The **Regression** column is that
question.

| # | Feature | Automated (A) | Static (S) | Runtime (R) | Regression check vs this branch |
|---|---|---|---|---|---|
| P1 | Indexing + identity reconcile (hash, split, collision) | `IndexerReconcileTests`, `IndexerDecisionTests`, `IndexerFastPathTests`, `IndexerConcurrencyTests` | 2026-08-01 | ✅ launch trace | ✅ all 5 identity seams carry tags + notes + **edits** |
| P2 | Tags per (file_id, parent_dir) | `TagScopeTests`, `TagFolderScopeTests`, `TagParentDirMigrationTests` | 2026-08-01 | ⚠️ G1 | ✅ scoping intact; ⚠️ **fixed R2-4** — edit-save sidecar export was rewriting tags |
| P3 | Star ratings (exclusivity) | `StarRatingTests`, `ReconnectRatingTests`, `SidecarHydrateRatingTests` | 2026-08-01 | ⚠️ G1 | ✅ both new importers write through `TagStore.setRating` |
| P4 | Per-file notes | `NoteStoreTests`, `ViewerFileDetailsNoteTests` | 2026-08-01 | ⚠️ G1 | ✅ carried by all rewrite seams; sidecar `noteAuthoritative` intact |
| P5 | Collections (manual, smart, living) | `Collection*Tests` ×12, `SmartCollection*Tests`, `SmartRule*Tests` | 2026-08-01 | ⚠️ G1 | ✅ `.location` + `.similar` rules added without disturbing existing resolvers |
| P6 | FTS5 search + scope toggle | `PhotoSearchTests`, `SearchBridgeTests`, `FtsEscapeTests`, `SearchQueryParserTests` | 2026-08-01 | ⚠️ G1 | ✅ `SearchMergeTests` pins folder-grain survival through the new semantic leg |
| P7 | Color search (CIEDE2000) | `ColorQueryTests`, `ColorDistanceTests`, `PaletteMatchTests`, `NamedColorTests` | 2026-08-01 | ⚠️ G1 | ✅ untouched |
| P8 | Duplicate finder + delete-to-trash | `DuplicateDeleteRulesTests`, `DuplicateKeeperTests`, `DeleteCoordinatorTests`, `TrashManagerTests` | 2026-08-01 | ✅ R7 modal opened, real dup pair listed (delete NOT run) | **Changed 2026-08-01:** every group now gets exactly one suggested keeper (`DuplicateFinder.keeperIndex`) — the old no-suggestion case showed KEEP on every tile and read as broken. Runtime re-check of the pre-marked default still owed |
| P9 | Grid virtualization + masonry | `MasonryGeometryTests`, `UniformGridLayoutTests`, `JustifiedRowsGeometryTests`, `GridSpacingTests` | 2026-08-01 | ⚠️ G1 | ✅ still virtualized — badges passed as parameters, never observed per tile (the cull badge that made this point was removed 2026-08-02; the rule is unchanged) |
| P10 | Grid selection, keyboard nav, page scroll | `GridSelectionTests`, `GridKeyboardNavTests`, `PageScrollTests`, `GridScrollRevealTests` | 2026-08-01 | ⚠️ G1 | ⚠️ **was broken, fixed R1-F16** — 5 new modals gated the key catcher with no Escape branch |
| P11 | Hero viewer (flight, zoom/pan, wash) | `ViewerGeometryTests`, `HeroPaletteTests`, `ImageHeaderSizeCacheTests` | 2026-08-01 | ✅ R7 opens on double-click, Escape closes | ⚠️ **fixed R2-1** — flight take-off rect used uncropped dims on a cold header cache |
| P12 | Thumbnails + decode budget | `ThumbnailVariantTests`, `ThumbnailStackKeyTests`, `ThumbnailWriteTests`, `DecodePermitTests`, `VisionDecodeTests` | 2026-08-01 | ✅ launch trace | ✅ unedited key byte-identical to pre-Spec-04 — no library re-keys on upgrade |
| P13 | QuickLook exclusion (video **and** audio) | `QuickLookExclusionTests`, `AudioArtworkTests` | 2026-08-01 | ⚠️ G1 | ✅ `mayUseQuickLook` still the single predicate; no new AV entry point bypasses it |
| P14 | AV no-network (`rmra`/`rdrf`) | — (enforced by construction) | 2026-08-01 | ⚠️ G1 | ✅ **verified: zero bare `AVURLAsset(url:)`/`AVPlayer(url:)` in the tree.** Spec 02's new `PhotoHeaderReader` uses the restricted helper |
| P15 | SVG viewer no-network (`WKContentRuleList`) | — | 2026-08-01 | ✅ (v1.5) | ✅ rule-list + deferred load + fail-closed all intact |
| P16 | Housekeeping prune (fail-closed) | `HousekeepingTests` | 2026-08-01 | ⚠️ G1 | ✅ root-visibility guard + `icloudRoot` param intact |
| P17 | Path reconcile by existence (fail-closed) | `PathReconcilerTests` | 2026-08-01 | ⚠️ G1 | ✅ `rootReachable` gate intact, still fire-and-forget |
| P18 | iCloud sidecars + hydration | `SidecarTests`, `SidecarStoreTests`, `EditSidecarTests`, `SidecarHydrateRatingTests` | 2026-08-01 | ⚠️ G1 | ⚠️ **fixed R2-4** — see P2. Sidecars now carry edits (Spec 04) with their own field clock |
| P19 | Backup / restore / reconnect | `BackupArchiveTests`, `BackupBuilderTests`, `ReconnectMatcherTests`, `ReconnectApplierTests`, `CollectionMaterializerTests`, **`BackupEditRoundTripTests`**, **`BackupArchiveCompatTests`** | 2026-08-01 | ✅ R7 save panel + correct default name (restore NOT run) | ✅ **no schema regression** — every v13–v23 `ADD COLUMN` is nullable. ✅ **G2 closed** — edit data now rides the archive (R3-1) |
| P20 | Collection → PDF export | `CollectionPDFLayoutTests`, `PaperSizeTests` | 2026-08-01 | ⚠️ G1 | ✅ routed through `OutputRender`, renders per-task, `discard`s each temp |
| P21 | Google Drive collection share | `DriveShare*Tests` ×4, `DriveMultipartTests`, `PKCETests`, `ImageMetadataStripperTests` | 2026-08-01 | ⚠️ G1 | ✅ render→strip→**verify** order preserved; all 3 upload loops `discard` |
| P22 | Share sheet / Open With | `EditCopyNamingTests`, `EditTransferTests` | 2026-08-01 | ⚠️ G1 | ✅ edited files now fork via `OpenWithFork` instead of silently handing over the original |
| P23 | Folder ops (subfolder, rename, move) | `FolderOpsTests`, `FolderRenameMigrationTests`, `FileMoveMigrationTests`, `FileMoverRenameTests` | 2026-08-01 | ⚠️ G1 | ⚠️ **was broken, fixed R1-F2** — edits rendered unedited after a rename until relaunch |
| P24 | Sidebar (folders, collections, reorder) | `SidebarCollectionSortTests`, `CollectionReorderStoreTests`, `ReorderMathTests`, `FolderOrderingTests` | 2026-08-01 | ⚠️ G1 | ✅ new LIBRARY section is additive and gated by its own setting |
| P25 | Analysis pipeline (Vision, palette, intent) | `Analyze*Tests` ×5, `PaletteExtractorTests`, `IntentCollectionsTests`, `ClustererTests`, `ReclusterGateTests` | 2026-08-01 | ✅ launch trace | ✅ traits/CLIP/header work added as new passes, not edits to the existing one |
| P26 | App Intents (Shortcuts/Siri) | — | 2026-08-01 | ⚠️ G1 | ✅ no signature change; reads go through the same stores |
| P27 | Localization (FR) | `VocabularyLocalizerTests`, `TagFallbackNamerLocalizationTests` | 2026-08-01 | ⚠️ G1 | ✅ **1,002 keys, 0 untranslated** (was 146 missing). ⚠️ **fixed R2-2** — a translated string was being persisted |
| P28 | Accessibility (VoiceOver) | `EscapeActionTests` | 2026-08-01 | ⚠️ G1 | ⚠️ **fixed R2-3** — Compare's rating + cull were keyboard-only, unreachable under VoiceOver |
| P29 | Sparkle update channel | — | 2026-08-01 | ✅ (v1.5) | ✅ untouched; `SUEnableAutomaticChecks` still true, EdDSA key intact |
| P30 | **HDR gain maps** (decode seam, HEIC tile cache, headroom through the edit chain, headroom-aware readouts, export) | `HDRDecodeTests` (14), `ThumbnailHDRCacheTests` (6), `EditRendererHDRTests` (5), `HistogramHeadroomTests` (6), `ImageExportHDRTests` (7), `ThumbnailCacheFormatResetTests` (5), `HDRReviewFindingsTests` (7) | 2026-08-03 | ❌ **OPEN — see the HDR runtime plan below** | New this work; `audit-invariants.sh` **HDR-1** is the standing regression gate |

---

## Part 2 — this branch (Foundation 1–7 / Specs 01–07)

| # | Feature | Automated (A) | Static (S) | Runtime (R) | Notes |
|---|---|---|---|---|---|
| S01.1 | v13 coordinates + backfill | `CoordinateMigrationTests`, `AnalyzeCoordinateWriteTests`, `DeepBackfillSelectionTests` | 2026-08-01 | ✅ trace | |
| S01.2 | The three edit-aware seams | `EditStackIndexTests`, `EffectiveDimensionsTests`, `OutputRenderTests` | 2026-08-01 | partial | ⚠️ **fixed R2-1** — `EffectiveDimensions.resolve` ordering |
| S01.3 | StoreKit plumbing (UNENFORCED gate) | `CommerceEntitlementTests`, `TrialGateTests` | 2026-08-01 | ❌ | Inert by design — G5 |
| S01.4 | Announcements channel | `AnnouncementFeedTests` | 2026-08-01 | ❌ | Off-able; ephemeral session; no body sent |
| S01.5 | Search cancellation + `PerfBaseline` | `SearchCancellationTests`, `PerfBaselineTests` | 2026-08-01 | ✅ trace | |
| S02.1 | `PhotoHeaderReader` (one-pass GPS + EXIF) | `PhotoHeaderReaderTests`, `PhotoHeaderBackfillTests`, `PhotoMetaMigrationTests` | 2026-08-01 | ✅ trace | Uses the reference-restricted AV helper |
| S02.2 | Offline reverse geocoding (`near:`/`in:`, `.location` rule, Info card) | `ReverseGeocoderTests`, `GeoKDTreeTests`, `GeoNamesDatasetTests` | 2026-08-01 | partial | No per-photo network — verified. **The Places PAGE was removed 2026-08-01** (owner) with the LIBRARY sidebar section; the geocoding underneath stays, `PlaceQueries`/`PlacesStore`/`PlacesPage` are gone |
| ~~S02.3~~ | ~~Rediscovery (On This Day / Rarely Seen / Shuffle)~~ | — | — | — | **REMOVED 2026-08-01** (owner: never approved, not in the spec). Whole LIBRARY sidebar section deleted with its stores, queries, views, tests and strings; the v16 `views` table stays in the append-only chain, unused |
| ~~S02.4~~ | ~~Near-duplicate stacks + bursts~~ | — | — | — | **REMOVED 2026-08-01** (owner: unwanted tile badge). Auto-stacker, manual stack menu, badge and the `visibleFiles` collapse seam all deleted; v17 `stacks`/`stack_members` stay in the chain, unused |
| S02.5 | Phase-1 token search + `.location` rule | `SearchTokenFacesTests`, `SmartRuleLocationTests`, `NLTokenComposerTests` | 2026-08-01 | ❌ G1 | |
| S03.1 | CLIP engine / index / model store | `ClipIndexTests`, `ClipVectorsTests`, `ClipPreprocessTests`, `ClipModelManifestTests`, `EmbedderTests`, `ClipMigrationTests` | 2026-08-01 | partial | Keyset-paged + bounded top-K (R1-F8) |
| S03.2 | On-demand model download | `SandboxProcessTests`, `ClipModelManifestTests` | 2026-08-01 | ✅ exec pinned | Fail-closed ladder; SHA-256 before unpack |
| S03.3 | `is:` / `faces:` / `pets:` / `similar:` tokens | `SearchTokenFacesTests`, `PhotoSearchTraitsTests`, `PhotoSearchSimilarTests`, `SimilarTermTests` | 2026-08-01 | ❌ G1 | |
| S03.4 | Compare workbench + focus peaking | `CompareTests` (was `CompareCullTests`), `PeakingOverlayTests`, `SharpnessScoreTests`, `PortraitHeuristicTests` | 2026-08-02 | ⚠️ G1 | ⚠️ **fixed R2-3** (VoiceOver). Survives the cull removal — rating, peaking and pane focus are untouched. |
| S03.5 | ~~Ephemeral cull + grid badge~~ | — | — | — | ❌ **REMOVED 2026-08-02 (owner call).** Marking rejects and trashing them at Finish is what select + Move to Trash already does; Muse's persona is a generalist, not a photographer culling a shoot. `CullStore`, `CullSummary`, the HUD, the resolve card, the grid key hook + badge, and 20 strings are deleted. **Cancelled, not a gap — do not re-file.** One real loss: the resolve card was the only BULK KEYBOARD RATING path, and the grid still has no number-key rating. |
| S03.6 | NL suggestions | `SearchSuggestTests`, `SearchSuggestTraitsTests`, `NLTokenComposerTests`, `LaunchBackfillQueryTests` | 2026-08-01 | ❌ G1 | ⚠️ **fixed R5-2** — the `in:` year facet labelled and stepped in UTC while `in:` itself resolves local |
| S04.1 | Edit model + codec + history | `EditStackCodecTests`, `EditStackNormalizeTests`, `EditHistoryTests`, `EditMigrationTests`, `GeometryParamsTests` | 2026-08-01 | ❌ G1 | Canonical hash pinned by literal fixture |
| S04.2 | Render chain (Core Image / Metal) | `EditRenderConsistencyTests`, `EditRenderNeutralityTests`, `EditKernelLoadTests`, `RenderCoalescerTests`, `CurveLUTTests`, `HighlightRecoveryTests` | 2026-08-01 | partial | RAW `scaleFactor` fixed R1-F3; non-RAW half **disproved** by measurement |
| S04.3 | `EditStore` + live provider + consumer sweep | `EditRecordStoreTests`, `EditStackIndexTests`, `EditSessionTests` | 2026-08-01 | ❌ G1 | ⚠️ **fixed R2-2** — persisted a translated version name |
| S04.4 | Editor UI (curve, WB, before/after, versions) | `EditSessionTests`, `CanvasPointMathTests`, `MiredMappingTests` | 2026-08-01 | ❌ **G1 — highest-value gap** | |
| S04.5 | Presets, copy/paste, Edit-a-Copy | `EditPresetStoreTests`, `EditCopyNamingTests`, `EditTransferTests` | 2026-08-01 | ❌ G1 | |
| S05.1 | Teaching histogram + clipping copy | `HistogramComputeTests`, `ClippingMessagesTests` | 2026-08-01 | ❌ G1 | |
| S05.2 | Tone-zone control + overlay | `ToneZoneMathTests`, `PhotoStatsQueriesTests`, `PhotoStatsMigrationTests` | 2026-08-01 | ❌ G1 | |
| S05.3 | "Why it looks this way" (deterministic) | `PhotoFeedbackTests` | 2026-08-01 | ❌ G1 | |
| S05.4 | `.cube` LUT import + registry | `CubeLUTParserTests`, `LutRegistryTests`, `LutStoreTests`, `EditLutMigrationTests` | 2026-08-01 | ❌ G1 | LUT read is off-main (R1-F6) |
| S05.5 | Looks browser (Styles) | — (UI) | 2026-08-02 | ⚠️ G1 | Single decode reused across cells. The **reference pane is REMOVED (2026-08-02, owner call)** — its editor row was `isEnabled: url != nil` with a tooltip pointing at a right-click in the GRID, i.e. a permanently-disabled control advertising a gesture in another view. `EditReferenceStore` and the menu item are deleted. Before/after + Side by Side cover comparison; `similar:` search covers "ones like this". **Cancelled, not a gap.** |
| S06.1 | One File > Import surface (5 sources) | `ImportPureTests`, `MetadataImportApplyTests`, `MetadataImportRulesTests`, `MetadataKeywordReaderTests` | 2026-08-01 | ❌ G1 | Re-run idempotency verified statically at every leg |
| S06.2 | Lightroom `crs:` edits + presets | `LightroomImportTests`, `XPresetRuleTests` | 2026-08-01 | ❌ G1 | |
| S06.3 | Color-label namespace + mapping sheet | `MetadataImportRulesTests` | 2026-08-01 | ❌ G1 | |
| S06.4 | Throttle / analysis status / import FYI | `WorkProgressTests`, `LaunchBackfillQueryTests` | 2026-08-01 | ✅ trace | Throttle now scales concurrency, not just pause (R1-F4) |
| S07.1 | Manifest v2 + three page layouts | `DriveShareManifestTests`, `SocialPresetTests` | 2026-08-01 | ❌ G1 | Page tests pass (`web/share/share.test.mjs`) |
| S07.2 | Portfolio mode (stable URL, live manifest) | `DriveShareStoreTests` | 2026-08-01 | ❌ G1 | Upload → atomic swap → sweep, rollback before swap |
| S07.3 | Social export card + render ladder | `SocialRenderTests`, `SocialCropMathTests`, `ExportMetadataTests` | 2026-08-02 | ❌ G1 | ⚠️ crop stage previewed the unedited original — fixed R1-F18. Card renamed `ExportCard`; social is now one branch of two |
| P29 | **General image export** (format · quality · depth · resize · background · presets) | `ExportFormatTests`, `ExportResizeTests`, `ImageExportRenderTests`, `ExportModelEstimateTests`, `ExportPresetStoreTests`, `SocialCropMathTests`, `OutputRenderTests` | 2026-08-02 (3 review rounds) | ✅ **driven 2026-08-02** | 72 unit tests + `MuseExportDriveTests` ×7, all green in the running app: card opens IN FRONT of the viewer and the editor, typing a size commits, the estimate resolves to a real byte count, the dropdown offers the formats and not the cut platforms, a social preset states its output size. Export itself stops at the powerbox panel — the bytes past it are `ImageExportRenderTests`' job |
| — | Migration chain v13→v23 | `MigrationChainTests` + 8 per-migration files | 2026-08-01 | ✅ replayed on real data | Pure DDL, O(1) at launch, endpoint pinned at v23. **Export added none** — presets are `AppSettings` JSON |

---

## Part 3 — editor adjustments batch (2026-08-02)

Spec: `docs/superpowers/specs/2026-08-02-editor-adjustments-batch-design.md`.
Plan: `docs/superpowers/plans/2026-08-02-editor-adjustments-batch.md`.

Two of these rows are not new features so much as **missing halves**: geometry
and vignette shipped in Spec 04 with a full model, renderer, codec and preset
carry, and nothing in the app could write either one. An audit found them by
checking every param type for a UI writer.

| # | Feature | Automated (A) | Static (S) | Runtime (R) | Notes |
|---|---|---|---|---|---|
| P31.1 | Vignette card (EFFECTS) | `EditStackNormalizeTests.testVignetteRoundTripsAtItsCanonicalIndex` | 2026-08-02 | ❌ | Model+renderer shipped in Spec 04; only the UI was missing. Post-crop for free — the renderer already applies geometry first |
| P31.2 | Auto-tone (three buttons: Light, Color, Auto Enhance) | `AutoToneStatsTests` (16), `AutoToneApplyTests` (6) | 2026-08-02 (round 10) | partial | Owner drove it and reported it flattened images — `targetSpread` was 0.62 against a normal photo's ~0.9, so contrast went NEGATIVE almost always. Retuned + clamped non-negative; four regression tests. **Re-drive to confirm the retune.** **The pre-render no-op is FIXED (2026-08-03).** Pressing Auto before the first render completed used to `return nil` silently, because `autoToneResult` bailed on a nil `originalImage`. It now renders the original on demand at `autoToneFallbackLongEdge` (1024) instead, so the press always does something; the normal path, where the render has landed, never reaches that branch. The window was always there and had just become easier to hit — entering Edit now seeds the canvas and skips the mount debounce, so the editor looks ready on the first frame instead of sitting empty, and nothing on screen said "not yet". (`seedCanvas` fills only `canvasImage`, never `originalImage`: the seed is the EDITED render, and passing it off as the original would corrupt before/after and auto-tone's own statistics.) |
| P31.9 | Tone-zone hover dwell | — | 2026-08-02 (round 10) | ✅ owner | Opening the card hatched the photo because `.onHover` fires when a view appears under a stationary cursor. 220ms dwell; drag floor 1pt → 3pt |
| P31.3 | HSL / COLOR MIX (`.hsl`, index 8) | `StageBParamsTests`, `EditKernelLoadTests.testHSLIsIdentityAtZero`, `…LeavesGreyUntouched` | 2026-08-02 | ❌ | 8 bands × 3 channels, one Metal kernel, after saturation and before the LUT |
| P31.4 | Split toning (`.splitTone`, index 9) | `StageBParamsTests`, `EditKernelLoadTests.testSplitToneIsIdentityAtZeroSaturation` | 2026-08-02 | ❌ | Display-referred, after the LUT. Five sliders, no hue wheel — darktable presents it the same way |
| P31.5 | Grain (`.grain`, index 10) | `StageBParamsTests`, `EditKernelLoadTests.testGrainIsDeterministicPerSeed` | 2026-08-02 | ❌ | Long-edge-normalized cell `(1.5+4.5·size)/4032`; seed from the file path so grid, screen and export agree. Renders LAST |
| P31.6 | Crop / straighten / rotate / flip | `CropDragMathTests` (24), `CropAspectPresetTests` (11), `GeometryParamsTests` | 2026-08-02 (round 10) | partial | Owner drove the card 2026-08-02 and found two bugs (see below). Model shipped in Spec 04; only the UI was missing. **Not yet driven on a ROTATED photo**, which is where round 10's coordinate-space fix lives — that is the open runtime check |
| P31.7 | Crop aspect menu | `CropAspectPresetTests` | 2026-08-02 | ❌ | Purpose + ratio at equal weight; social rows read `SocialPreset.nameKey` so the two surfaces can't drift |
| P31.8 | Straighten auto-inset | `CropDragMathTests.testStraightenInsets*` (4) | 2026-08-02 | ❌ | Only auto-manages a crop it owns. Not destructive — writes a `crop` value, reversible by double-clicking the slider |

**Runtime column = the GUI test plan for this batch.** The owner drove parts of
it on 2026-08-02 and it found four bugs (round 10 in `REVIEW-LENSES.md`), which
is the argument for this column existing. Rows still ❌ have genuinely not been
driven. What remains to be checked, in order:

1. **EFFECTS** — drag Vignette, corners darken; double-click Midpoint returns
   to **0.5**, not 0.
2. **Auto in LIGHT** on an underexposed photo — exposure/contrast/blacks/whites
   move, Temperature and Tint do **not**. Press again: nothing changes.
   ⌘Z undoes it in one step. Then **Auto in COLOR** — the mirror.
3. **COLOR MIX** — Saturation tab, pull Blue to −1 on a sky photo. Only the sky
   desaturates. Switch to Luminance: the eight sliders show that channel.
4. **SPLIT TONE** — shadow saturation up, then shadow hue; the shadows tint and
   the highlights don't. Balance shifts where the split falls.
5. **Grain at 1.0 → look at the GRID TILE.** The grain must be visible there,
   not only in the editor. A clean tile means the thumbnail path isn't applying
   the stack, and that is a bug to fix, not to accept — the grid is the product.
6. **CROP** — press Crop: the frame appears over the **whole** photo. Drag a
   corner, the outside dims. Pick "Square 1:1", the frame snaps centred. Apply:
   the canvas renders cropped and the mode ends. Re-open Crop: the whole photo
   is back with your rectangle on it. **The grid tile reflows to the new aspect**
   — intended, see spec §6.5.
6b. **CROP ON A ROTATED PHOTO — the open one.** Rotate 90°, then crop the TOP
   band of what you see, then Apply. The result must be the top of what you were
   looking at. Before round 10 it was the LEFT band of the original, because the
   crop is stored in source space and the canvas shows display space. Fixed and
   unit-tested over all four turns and both flips, but not yet driven.
6c. Turn **Side by Side** on while crop mode is active — crop mode must switch
   itself off rather than draw a frame across both panes.
7. **Straighten to 10°** — the photo tilts and stays a filled rectangle, no
   transparent corners. Double-click the label: back to 0 and full frame.
8. **Batch** — select several photos, copy a crop and a vignette onto them via
   the selection menu. Should work with no new code (`AdjustmentGroup` already
   carried `.geometry`/`.vignette`).

## Review rounds

| Round | Date | Scope | Findings | Suite after |
|---|---|---|---|---|
| 1 | 2026-08-01 | Specs 01–07, ten sweeps / eight slices (`REVIEW-FINDINGS.md`) | 23 fixed (F1–F23) | 1,775 |
| 2 | 2026-08-01 | Regression of pre-branch features under this branch's seams, + lenses round 1 didn't run | 4 fixed (R2-1…R2-4) | 1,783 |
| 3 | 2026-08-01 | The two gaps round 2 recorded rather than closed | G2 + G6 closed | 1,795 |
| 3-QA | 2026-08-01 | Self-review of round 3's own diff | 4 fixed (see below) | 1,797 |
| 4 | 2026-08-01 | Lenses rounds 1–3 did not run: SQL construction, crash-on-user-data, resource lifecycle, remote-body bounds; + a third check of the twice-recurring index-staleness class | 4 fixed (R4-1…R4-4) | 1,802 |
| 5 | 2026-08-01 | Lenses rounds 1–4 did not run: **time-zone correctness of SQL date parts**, path-prefix boundaries, Unicode path normalization, comparator ordering, transaction atomicity, task-group concurrency bounds | 2 fixed (R5-1, R5-2) | 1,806 |
| 6 | 2026-08-01 | Lenses rounds 1–5 did not run: **arithmetic traps on file-declared numbers**, untrusted metadata → filesystem path, bounds on the model download's PAYLOAD leg (round 4 bounded only the manifest), local log/trace leakage | 4 fixed (R6-1…R6-4) + 1 self-QA | 1,818 |
| 7 | 2026-08-01 | **Method change, not a seventh set of angles.** Mechanized the greppable durable rules (`scripts/audit-invariants.sh`, 12 checks, all negative-tested) and started the lens registry (`REVIEW-LENSES.md`) so "static review is done" became checkable. Lenses rounds 1–6 didn't run: spec→code existence, dead code, schema downgrade, nil-`dbQueue`, observer lifetime, cross-process DB | R7-1 (region similarity never built — product call), R7-2 (2 dead files removed), R7-3 (dev-only multi-instance note) | 1,818 |
| 7b | 2026-08-01 | **Drove the running GUI** via XCUITest (G1 partially closed) + the tag chip row's per-hover layout cost | R7-4 fixed (chip measurement cache); 7 vacuous UI assertions strengthened; 3 test defects of my own | 1,818 + **20 UI** |

### Round 2 findings

| # | Severity | Finding | Fix |
|---|---|---|---|
| **R2-1** | med | **`EffectiveDimensions.resolve` returned UNCROPPED dimensions on a cold header cache.** It asked for the crop first, but `EditStackIndex.croppedSize` scales the crop against `ImageHeaderSizeCache.cached` — a no-I/O lookup that answers nil until something warms it. Both callers (the Info card's dimensions row, the hero flight's take-off rect) document that they want the post-crop size. The grid's masonry path had the same shape, and worse: it marked the path `resolved`, so only the visible-tile `report` backstop could ever correct it. | Resolve the header FIRST, then ask for the crop. In `AspectRatioCache` the warm-up is gated on the file actually carrying an edit, so the cost is bounded to a rare case. |
| **R2-2** | low | **A translated string was persisted to the database.** `EditStore.switchToVersion` auto-preserves the outgoing stack under `String(localized: "Previous")`, writing "Précédent" into `edit_versions.name` on a French system — against the app-wide "storage stays canonical-English, localize at display" rule that every other Muse-derived label follows. | `EditVersionName`: canonical `"Previous"` stored, localized at display. User-typed names pass through untouched. |
| **R2-3** | med | **Compare's two primary actions were unreachable under VoiceOver.** Rating (0–5) and cull marking (K/X/U) are handled by `CompareKeyCatcher`, and VoiceOver swallows plain character keys before an `NSView` sees them. Exactly the gap round 1 fixed for the grid's cull marks — the same reasoning, one surface further on. | Named accessibility actions per pane (rate 1–5, clear rating; keep/reject/clear while a cull session is running). |
| **R2-4** | **high** | **An edit save could wipe another device's synced tags.** `Sidecar.resolveForWrite`'s non-merge path takes tags from `fresh` wholesale — right for a *tag* edit, wrong for the edit-save export, which uses the same path. A device that hasn't hydrated a sidecar yet has those tags in neither its DB nor `fresh`, so saving an edit rewrote the sidecar's tag list without them. The same hazard is already guarded for `note` and `edit_stack` on that exact write. | `tagsAuthoritative` parameter; the edit export passes `false` and tags UNION instead (single-rating resolution preserved). +4 tests. |

### Round 3 findings

| # | Finding | Fix |
|---|---|---|
| **R3-1** | **G2 — a `.muselibrary` restore lost every edit.** Spec 04 §5.3 claimed the archive "carries the DB"; it does not — `.muselibrary` is a JSON encode of `BackupArchive`, and occurrences carried tags + note and nothing else. Restoring a library silently dropped every edit stack, version, preset and LUT. | Spec 09 A2, implemented as specified. `BackupOccurrence` gains `edit_stack` / `edit_updated_at` / `edit_versions`; `BackupArchive` gains library-global `edit_presets` and `edit_luts` (bytes carried — a stack whose LUT is missing renders as the original, so dropping them would be a half-restore). Schema stays **1**: every field is optional-with-nil-default, so pre-A2 archives decode unchanged and post-A2 archives still decode on pre-A2 builds. Restore is **restore-wins** at the new `parent_dir` (matching the note and rating lines), versions get **fresh UUIDs but are deduped by CONTENT** so re-running Restore is idempotent, presets/LUTs are `INSERT OR IGNORE` (the LUT content-hash PK makes that the immutability rule) and apply ONCE per restore rather than per folder. Absence is deliberately **not** a reset — it means the backup predates the edit. Post-apply runs `EditStore.applyHydratedConsequences` + `LutRegistry.invalidate`, without a sidecar re-export, and sits OUTSIDE the collection-map branch so a failed hash map can't leave edits in the database with nothing on screen knowing. +14 tests. |
| **R3-2** | **G6 — 442 Swift 6 strict-concurrency warnings** (221 unique × two arches; round 2 estimated ~60 from a partial build and was wrong). The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so every unannotated declaration is `@MainActor` — including pure value math and DB helpers that only ever run inside GRDB closures and detached tasks. | Marked the declarations `nonisolated` at the type/member level, which is the idiom the codebase already used for `Sidecar`, `EditStackIndex` and friends. Separately, ~13 sites captured a mutable `var` across a `@Sendable` closure — real races the compiler could only warn about. The read-only ones are frozen into a `let` before the closure; the mutated ones (four importers, `AutoStacker`) now **return a result struct from the closure** instead. Also fixed a genuine no-op downcast in `PerfBaseline` that made "no database" and "empty library" indistinguishable, a non-Sendable `FileManager` captured in a write closure, and a `DirectoryEnumerator` for-in that is unavailable from async contexts. **Release build is now warning-free.** |

### Round 3 self-QA — defects found in round 3's own work

Reviewing the round-3 diff turned up four defects I had introduced, all in the
backup leg. Recorded because the pattern is the point: three of the four are the
SAME classes earlier rounds had already fixed elsewhere, reintroduced by new code.

| # | Severity | Defect | Fix |
|---|---|---|---|
| 1 | med | **Restore's folder walk could terminate early.** Converting the enumerator to `nextObject()` (for the async-context warning) as `while let url = en.nextObject() as? URL` reads fine and is wrong — a single non-URL element ENDS the loop instead of skipping it, silently indexing only part of the folder. During a restore that surfaces as unmatched occurrences the user is asked to eyeball. | `while let next = en.nextObject() { guard let url = next as? URL else { continue } … }` |
| 2 | **high** | **Edit rows could land in the database with nothing on screen knowing.** `applyEditAssets` and the edit-save consequences were nested inside the `if let map = currentFileIDForHash` branch, which neither needs — while `applyMeta` writes the edit rows unconditionally above it. A failed hash map therefore restored the edits but left `EditStackIndex` (path-keyed, built at launch) and the thumbnail cache stale until relaunch. **Exactly the R1-F2 defect class**, in new code. | Both hoisted out of the branch. |
| 3 | low | **Re-running Restore duplicated every version.** Fresh UUIDs per insert made a second restore of the same archive additive, against Spec 09's own "idempotent re-apply". | Identity is the CONTENT (`kind`+`name`+`stack`+`created_at` at that scope); ids stay fresh. +2 tests. |
| 4 | low | **Library-global assets rewritten per folder, and a failed write latched.** `applyEditAssets` ran for every reconnected folder — `INSERT OR IGNORE` is correct but SQLite still binds each ≤25 MB LUT blob before detecting the id conflict, so a ten-folder restore pushed hundreds of MB through the writer for nothing. The once-only guard I first wrote then latched even when the call FAILED, silently costing every preset and LUT. Separately, the new versions-dedup query ran per matched occurrence including unedited ones — the R1-F15 per-file-query shape. | Once per restore, latched only on success; the dedup read moved inside the emptiness guard. |

### Round 4 findings

Round 4 deliberately avoided re-running rounds 1–3's lenses and picked ones
they hadn't: how SQL is *constructed*, crash-on-user-data, resource lifecycle
(contexts, caches, observers, scopes), and whether remote bodies are bounded
while being read. Two of the four are the same defect expressed twice — a
resource meant to be shared being rebuilt per item.

| # | Severity | Finding | Fix |
|---|---|---|---|
| **R4-1** | med | **A `CIContext` was constructed per image on the automatic analysis path.** `VisionServices.dominantColorHex` built its own context per call, and `analyze` runs it for EVERY indexed image — so a first index of a large folder created and tore down one GPU-backed context per file. The editing side already treats contexts as long-lived shared resources (`RenderContexts`, `SocialRender.context`, `PeakingOverlayView.context`); this site was simply missed. | One `static let` context for the whole pass, with `.cacheIntermediates: false` — deliberately, since a *caching* shared context would be strictly worse than the per-image one: every image is area-averaged exactly once and never revisited, so intermediates off a full-size input could only grow across a bulk index, never hit. sRGB working space unchanged, so `dominant_color` values are byte-identical. |
| **R4-2** | low | **`LutRegistry`'s LRU could evict a live entry.** The miss path released the lock to hit the database, then appended the id to `lruOrder` blind. Two threads missing the same id therefore appended it twice; the eviction loop then dropped the live cache entry on the first copy while the second lingered as a phantom. `preload` already deduped — the read path was just inconsistent with it. | `lruOrder.removeAll { $0 == id }` before the append, matching `preload`. |
| **R4-3** | med | **The announcements feed's size cap was applied after the bytes were already in memory.** `AnnouncementFeed.parse` guards `data.count <= maxPayloadBytes`, but `URLSession.data(for:)` buffers the whole body before returning — so the response chose the allocation and the "cap" only decided whether to parse it. This is the app's ONLY automatic, non-user-initiated fetch, and it runs at every launch. The share page's `readCapped` documents this exact reasoning on the JS side ("a check performed on memory already allocated"); the Swift side hadn't applied it. | `BoundedBody.data(for:session:limit:)` — rejects on a declared oversize Content-Length before reading a byte, and enforces a streaming tally when the header is absent or lies. Wired into the announcements fetch and the CLIP manifest fetch (which likewise declared a 16 KB ceiling it couldn't enforce). +5 tests, incl. the two cases a post-hoc check passes: an understated Content-Length and no Content-Length at all. |
| **R4-4** | — | **Structure:** `BoundedBody` first landed in `Commerce/`, which made `Intelligence/Clip/` depend on a commerce folder for a cross-cutting network utility. | Moved to its own `Networking/`. |

### Round 5 findings

Round 5 picked lenses the first four hadn't: **time-zone correctness of SQL date
parts**, path-prefix boundaries, Unicode path normalization, comparator ordering
(strict weak), transaction atomicity, and concurrency bounds on task groups. Both
findings are the same defect class — an epoch column read as UTC by SQL while
every Swift input to the same comparison was built in the local zone — and both
were invisible to the existing tests because their fixtures happened to use
midday-UTC epochs that read as the same calendar day either way.

| # | Severity | Finding | Fix |
|---|---|---|---|
| **R5-1** | med | **On This Day showed evening photos on the wrong day.** `RediscoveryQueries.onThisDay` compares against two local-zone inputs (`todayMD`/`currentYear` from a `Calendar`, and `capture_md`, which `PhotoHeaderReader.monthDay` materializes with a default-zone `DateFormatter`) — but its `created_at` fallback leg tested `strftime('%m-%d', …, 'unixepoch')`, which is **UTC**. Verified in SQLite: a photo at 2020-06-21 22:00 PDT reports `06-22`. So in the Americas every evening file surfaced on the *following* day's anniversary and was missing from its own. The function's own comment calls the fallback "a set that shrinks toward zero as the header backfill completes", which is not true: `photoKinds` includes **video and psd**, which rarely carry an EXIF capture date and therefore live on `created_at` permanently. The year exclusion had the same UTC-vs-local mismatch at New Year. | `'localtime'` on all three date parts, plus a comment recording why local is the correct zone here rather than an arbitrary choice. +2 tests, both pinned to `America/Los_Angeles` and both verified to FAIL against the old SQL. |
| **R5-2** | med | **A search facet offered a year that matched nothing, and hid one that would have.** `SearchFacets.distinctYears` labelled years with a UTC `strftime`, but the token it feeds (`in:<year>`) resolves its bounds through a local `Calendar` in `PhotoSearch.dateIDs`. A single 2019-12-31 20:00 PST photo was therefore offered as **2020**, which `in:2020` then matched nothing for — breaking the "no empty year is ever offered" promise the function documents. Worse, the recursive CTE *stepped* by a UTC year too, so from that same photo the step jumped clean over a following June-2020 capture and **2019 never appeared in the list at all**. Both halves reproduced in raw SQLite before fixing. | Local label + local step, via `datetime(t,'unixepoch','localtime','start of year','+1 year','utc')` — `'utc'` closes the arithmetic back to an epoch, so the comparison still runs against the stored integer and the loose index scan is unchanged. Verified the step is still strictly increasing (so the CTE cannot fail to terminate). +2 tests, both verified to fail against the old SQL. |

The class is now closed: the only two `Calendar` sites in the app target are
`RediscoveryStore` and `PhotoSearch.dateIDs`, and after these fixes every SQL
date part they meet is evaluated in the same zone they are. The rule is recorded
in `docs/durable-constraints.md` § Photo metadata, and
`MuseTests/TestTimeZone.swift` gives the shared `withTimeZone` helper such a test
needs — without it these assertions pass vacuously on a UTC machine.

### Round 5 — checked and clean

Recorded so a later round doesn't re-spend the effort:

- **Path-prefix boundaries are sound.** Every one of the 19 `hasPrefix` path tests either appends `"/"` explicitly or is a non-path domain (a filename prefix, a URL prefix). `PathReconciler.excludingProtected` normalizes the trailing slash before testing, so an unreadable `/a/Inspo` cannot protect `/a/Inspo Extra/x.jpg`.
- **No Unicode-normalization hazard.** There is no NFC/NFD normalization anywhere in the tree, which is safe *because* every path in the DB originates from filesystem enumeration and is compared against paths from the same source — there is no user-typed or archive-supplied path joining that comparison.
- **No LIKE-metacharacter correctness bug.** Distinct from round 4's injection sweep. `SmartCollectionResolver`'s `.filename` rule uses LIKE only to pre-narrow and then re-tests the basename literally in Swift, so a `%` or `_` in the term over-matches the cheap leg and is rejected by the exact one. `NoteStore` escapes explicitly with `ESCAPE`.
- **Transaction atomicity is correct by construction.** There are no `inTransaction`/`savepoint` calls because GRDB already wraps every `write { }` closure in a transaction — which is why all 76 write sites are atomic without saying so.
- **Comparators are valid strict weak orderings.** No multi-key `||` comparator exists; the one tuple comparator (`onThisDay`'s ordering) tests inequality before falling through to a total tiebreak on `id`.
- **Task groups are concurrency-bounded.** Six of the seven use an explicit in-flight window (`Indexer`, `AnalyzePipeline`, `DeepAnalysisBackfill`, `PhotoHeaderBackfill`, `ThumbnailCache.prewarmToDisk`, `CollectionPDFExporter`). **`AspectRatioCache.load` is the one exception** and is left as-is deliberately: it is fed `visibleFiles` (the whole filtered set, not a viewport window), so `gaps` can be folder-sized, but real parallelism is bounded by Swift's cooperative pool and the unwindowed spawn is a documented choice for layout convergence speed. Worth knowing rather than fixing: it is the only background pass that does **not** narrow under `WorkThrottleStore`, and its `Task.detached` work is not cancellable — a superseded folder's reads run to completion and are discarded by `loadToken`.
- **GPS is validated on both ingest paths** — `PhotoHeaderReader` guards `isFinite` plus per-axis bounds, `XMPGPS` guards the same, so corrupt EXIF cannot reach the KD-tree.

### Round 4 — checked and clean

Recorded so a later round doesn't re-spend the effort:

- **No SQL injection surface.** Every interpolated SQL fragment in the tree is either placeholder-generated (`qmarks`/`placeholders`/`marks`) or a compile-time literal / enum-derived column name; every value is bound. The two `column:`-parameterized helpers in `PhotoSearch` are called only with literals.
- **No crash-on-user-data found.** Zero `try!` and zero `fatalError`/`preconditionFailure` in the app target. Every unchecked-looking subscript is guarded first — notably `CubeLUT.parse`, which is the one parser fed a user-supplied file, and which `guard`s `parts.count == 3` before every triple access and bounds both file size and LUT size.
- **A third pass over the index-staleness class found no third instance.** R1-F2 (rename) and R3-QA-2 (restore) were both "edit rows changed, `EditStackIndex` didn't". Enumerated every mutation of an edit row or a path and confirmed each refreshes: `save` → `applySaveConsequences` (this also covers the **Lightroom `crs:` importer**, which routes through `EditStore.save` rather than writing rows directly), `applyHydrated` → `SidecarHydrator`, `applyRestored` → `ReconnectModel`, `rewriteParentDirPrefix` + file move + file rename → `rebuildIndex`. `Indexer`'s `carry`/`carryAll` leave the path→stack mapping unchanged by construction.
- **Observers and timers are balanced.** The only `addObserver` sites without a matching `removeObserver` are `ToolbarFade`'s two, both `static` behind install-once guards (app-lifetime, intentional), and `AppState`'s three (singleton). The one repeating `Timer` is `[weak self]`.
- **Security-scoped resource starts are accounted for.** The one unbalanced `start` (`openStarred`) is deliberate and documented — a pin is meant to stay reachable — and is deduped per path so re-opening can't leak a scope per open.
- **The share page holds up.** `web/share/share.js` renders every attacker-suppliable field via `textContent`, sanitizes bidi/zero-width/control characters, caps inflate output against a zip bomb, byte-caps the portfolio fetch *while streaming*, and refuses to chain fetches. No `innerHTML`, no `href` built from the manifest.

### Round 2 — checked and clean

Recorded so a later round doesn't re-spend the effort:

- **No unsanctioned AV entry point.** Zero bare `AVURLAsset(url:)`/`AVPlayer(url:)` in the tree; Spec 02's new `PhotoHeaderReader` uses the restricted helper.
- **No unextracted user-facing strings in the branch** — no AppKit setter or custom-view `title:`/`label:` param carries a bare literal.
- **`modalPresented` and `dismissTopModal` agree entry-for-entry** (26 each).
- **No migration regression for backup/restore** — every v13–v23 `ADD COLUMN` is nullable.
- **`OutputRender` choke point holds** — all 6 `forOutput` call sites, `discard` wired at every one that owns its temp, backup still deliberately excluded.
- **Header-size cache records ORIGINAL dimensions**, so the crop is applied exactly once.
- **Every automatic (no-click) decode site is still budget-guarded.**
- Two files that read as unreferenced (`SocialExportCard`, `LibraryRows`) are both wired — the entry-point type name simply differs from the filename.

### Round 3 self-QA — checked and clean

- **No class marked `nonisolated` lost real protection.** The only two are `SearchCancellation` (NSLock-guarded, already `@unchecked Sendable`) and `KeychainTokenStore` (two `let` strings; all state lives in the thread-safe Keychain). Everything else marked was a struct, enum, or pure static.
- **`AppSettings`' mutable UserDefaults-backed vars stayed main-actor** — only pure constants and clamp functions there were marked.
- **All four importer refactors are semantically faithful** to the `var`-mutation versions they replaced; the one difference is that a thrown transaction now discards its partial outcome instead of leaving an outer array mutated, which is the more correct direction.

---

## Maintaining this ledger

- A new feature gets a row **in the same PR that builds it**, with `R` set to ❌ until someone drives it.
- A review round appends a section above and updates the state columns it actually established.
- When G1 is closed, the ❌/⚠️ marks in the **Runtime** column are what needs walking — that list is the GUI test plan, already written.


### Round 6 findings

| # | Severity | Finding | Fix |
|---|---|---|---|
| **R6-1** | med | **The model download bounded its manifest and nothing else.** Round 4 gave `ClipModelManifest.parse` a 16 KB streaming ceiling on exactly the reasoning that a cap applied after the bytes are in memory bounds nothing — then left the payload leg calling `session.data(from:)` per chunk with no ceiling of any kind. `totalBytes` was parsed and never read, which was the tell. Chunk NAMES were also unvalidated while being appended to the manifest's directory URL, so a `../…` name aimed the fetch at another path on the host; the SHA-256 that follows proves the assembled bytes, not their provenance or their cost. | `parse` now bounds `totalBytes` (`1...maxArtifactBytes`), the chunk count, and every chunk name (`isSafeChunkName` — one plain path component). `streamChunks` spends `totalBytes` as an allowance, per chunk, and refuses an overrun. Unpack now fails closed if any extracted entry is a SYMLINK — the one entry kind a verified archive can still use to write outside the directory. +5 tests. |
| **R6-2** | med | **`Int(someDouble)` on numbers a FILE declared — a trap, in five places.** Swift's `Int(_:)` is not a clamping conversion: it raises SIGTRAP on NaN, on infinity, and past `Int.max`. `FileMetadata.formatFrameRate` (a track's `nominalFrameRate`), `loadVideo`'s natural size, `formatDuration` (`+inf` passes its `> 0` guard), `formatExposure` and `PhotoFeedback` (`1/shutterSeconds` overflows for a subnormal EXIF value), and `LightroomXMP.int` all did it. The Info card loads on hero open, so most of these crashed the app on *selecting* a file; the XMP one crashed "Import Keywords & Ratings" mid-run, over the whole library, on one bad packet. `SmartCollectionRulesView` already clamped before an `Int64()` and said why — the reasoning existed in one spot and had never been generalized. | `Int(exactly:)` throughout, plus an `isFinite` guard wherever a `> 0` test would otherwise admit infinity. Unrepresentable reads as absent, which every caller already handled. Trap reproduced at runtime (exit 133, "the result would be greater than Int.max") before fixing. +5 tests. |
| **R6-3** | med | **An Eagle library's `metadata.json` wrote outside the folder the user picked.** `name`/`ext` are third-party data — an Eagle library can be downloaded, shared or synced — and both were turned into a path twice: `infoURL.appendingPathComponent(name)` to find the source file *inside* the library, and the same string appended to the import DESTINATION. A `name` of `../../…` escaped both. | `EagleLibrary.safeComponent` at the parse seam, so both uses inherit it. Rejects rather than rewrites: a sanitized name would still copy the file under a name the library never asked for. New `EagleImportSafetyTests`. |
| **R6-4** | — | **Self-QA of this round's own diff.** The first cut of R6-1 routed each model chunk through `BoundedBody`, which walks a body **one byte at a time** to enforce its ceiling exactly. That is right for a 16 KB manifest and would spend minutes of CPU on a hundreds-of-MB artifact — a severe throughput regression introduced *by the fix*. | `session.download(for:)`, which spools to a temp file (RAM flat regardless of what the server sends) and matches the surrounding function's own stated reason for streaming to disk. The chunk is appended and hashed in 4 MB slices via do/catch, not `try?`, so a read error and a clean EOF can't collapse into the same nil and report a truncated copy as success. |

### Round 6 — checked and clean

Recorded so a later round doesn't re-spend the effort:

- **The rest of the numeric-conversion surface.** Every `Int(`/`Int64(`/`UInt64(` on a floating-point expression in the app target was read. All the others are safe *by provenance*, not by luck: `VisionServices` and `ThumbnailCache` convert `CGImage`-derived integers; `HistogramCompute.binIndex` takes `UInt8` pixel values, so its `min`/`max` clamp can never see NaN; `EditRenderer`'s curve index is `i/63` over a fixed-size LUT; `ReconnectModel.overallPercent` guards `total > 0` before dividing; `SmartCollectionRulesView` was already clamped.
- **Locks and reentrancy.** No `await` inside any of the seven `NSLock` critical sections; no nested GRDB access.
- **Unbounded in-memory growth.** `ImageHeaderSizeCache` caps at 20,000 entries and documents why it drops the whole table rather than trimming. The other long-lived tables are keyed by edits or LUTs, not by library size.
- **File-write atomicity.** Every durable write outside the DB uses `options: .atomic` / `atomically: true`. The exceptions are the phase-trace log (append-only, env-gated) and the model artifact (deleted wholesale on any failure).
- **Local leakage.** `PhaseTrace` is env-gated behind `MUSE_TRACE`/`MUSE_PERF` and stores nothing when off. The 21 non-DEBUG `print` calls are all error-path diagnostics; exactly one (`Indexer`, on a write failure) includes a user path, as do three `NSLog` error paths in `FolderOps`/`FileMover`. These go to the local system log, not off the machine — acceptable, and noted so it isn't re-derived.
- **The other importers' path construction.** Takeout builds its sidecar ladder from `url.lastPathComponent` of an enumerated file; the share extension's `uniqueDestination` and `OutputRender`/`SocialRender`'s temp stems likewise come from real enumerated URLs. Only Eagle took a name that arrived as *data*.
- **The `.muselibrary` archive is deliberately NOT size-bounded on read.** It is a file the user explicitly picked, and a legitimate archive of a large library now carries LUT bytes, so a cap would refuse real backups to defend against a file the user chose to open. Deliberate, unlike the import sidecars, which are walked in bulk without the user seeing them (`BoundedRead`).

---

## Round 7 (2026-08-01) — mechanization, and the lens that found the gap

Round 7 changed the method rather than adding a seventh set of angles. Rounds
1–6 each found real bugs by running lenses the previous rounds hadn't, which
works but never terminates — the lens space is unbounded, so "review until
green" had no exit criterion. Two artifacts now supply one:

- **`scripts/audit-invariants.sh`** — 12 checks, each a rule that was broken
  once, shipped, and cost a session. A shell script rather than an XCTest on
  purpose: `EditingModuleImportTests` already tries this as a grep test and
  **skips** here, because the test host is the sandboxed app and the checkout
  lives in `~/Documents`. A source-tree check inside the suite passes vacuously
  exactly where it is needed.
- **`docs/new-build/REVIEW-LENSES.md`** — every lens ever run, plus the ones
  not yet run. A round is now "run the registry", not "invent angles", and
  static review is *done* when the unrun list is empty and the audit is green.

**Every audit check was negative-tested** — verified green on a clean tree, then
verified to FAIL when its violation is injected. Two were wrong on first
writing, both in the same way: they matched a rule being *discussed in a comment*
as the rule being *broken*. `ENT-1` flagged the very comment explaining that
iCloud is deliberately omitted, and a draft `NET-1` flagged `ViewerInfoColumn`
for a comment stating the app never uses `URLSession` there. A checker that cries
wolf gets ignored, so both now strip comments. `ARCH-1` was also rewritten from
file-level to line-level: a "does this file mention `#if arch(arm64)`" test would
have passed the exact regression it exists to catch, since `ClipVectors` has two
correctly-guarded uses that would alibi a third bad one.

### Round 7 findings

| # | Severity | Finding | Disposition |
|---|---|---|---|
| **R7-1** | ~~med~~ → dropped | **Spec 03 §5 "Region similarity" was specified and never built.** The spec describes crosshair, marquee drag, `RegionSearch.minSide = 24`, crop embedding, a "region"-labelled similar search, and an Escape branch that exits region mode rather than the viewer. Only `Components/RegionMath.swift` — the pure geometry helper — exists. No `regionMode`, no `RegionSearch`, no marquee. Found by a spec→code symbol sweep across `Muse/`. **Third instance of this branch's signature failure**, after the grid cull badge and the five missing Escape branches: the pure, testable half of a feature lands and gets tests, the UI that makes it reachable does not, and the suite stays green. | **RESOLVED 2026-08-01 — owner DROPPED the feature.** `RegionMath.swift` and `RegionMathTests` deleted. Rationale: whole-photo "Find Similar Photos" already ships (CLIP `similar:` search, right-click a photo), and anything with a WORD is already reachable through tag search — region mode only added "more like this crop" for visual qualities that have no name. Not worth the UI. **This is a cancelled spec section, not an open gap; do not re-flag it.** |
| **R7-2** | low | **Two dead view files.** `BreadcrumbView.swift` (53 lines, phase 0.5, zero references, doc comment promising clickable navigation its plain `Text` segments never implemented) and `ImageDetailPanel.swift` (15 lines, self-described "Phase 0 placeholder", superseded by `ViewerInfoColumn`). | **Removed.** Xcode 16 `fileSystemSynchronized` groups, so no `pbxproj` edit needed. Release build green. |
| **R7-3** | note | **Multi-instance is a dev hazard and was live during this review.** `Database.swift` states the assumption — *"Single writer, single process"* — and it holds for shipping: the share extension genuinely does not open the database (verified: no GRDB reference in `MuseShareExtension/`), and LaunchServices won't start a second instance normally. But GRDB's `busyMode` defaults to `.immediateError`, never overridden, so a cross-process write throws `SQLITE_BUSY` with no retry — into a lot of `try?`. Two instances were running here via `open -n`/Xcode. | **No code change** (unreachable for a shipping user). **Quit all but one instance before the G1 GUI pass**, or phantom "my edit didn't save" bugs will be chased. |

### Round 7 — checked and clean

- **Schema downgrade** (an older build opens a v23 DB, e.g. after a Sparkle
  rollback). GRDB's `runMigrations` computes applied migrations from *known*
  identifiers only, so the unknown newer ones are ignored and it no-ops rather
  than erroring or erasing. Every v13–v23 addition is a nullable `ADD COLUMN` or
  a new table, so an old build writing rows leaves them NULL, and the
  hash-gated backfills re-run and self-heal on the next upgrade. Survivable.
- **Nil `dbQueue` fallout.** When migration fails, `Database.shared.dbQueue` is
  nil and the app continues. Every consumer `guard let … else { return }`s and
  no-ops; `Housekeeping.pruneUnreachable` — the permanent delete — takes a
  non-optional `DatabaseQueue` and is called under `if let`, so it cannot run at
  all. Fails safe, no destructive path reachable.
- **Observer and resource lifetimes.** The only `NotificationCenter` observers
  are three in `AppState` (a singleton, so app-lifetime by construction) and two
  in `ToolbarFade`, both `static`, both install-once guarded, both capturing no
  `self`. No `removeObserver` is needed anywhere; nothing leaks.
- **Accessibility on the surfaces this branch added.** `Views/Editor`,
  `Views/Compare` and `Views/Export` all carry labels. The single file using SF
  icons with no accessibility treatment at all was `BreadcrumbView` — dead code,
  now removed.

### Suite and build state after round 7

**1,818 tests, 2 skipped, 0 failures** in `MuseTests`, plus **6** `MuseUITests`.
Release build **0 warnings, 0 errors**, universal (`x86_64 arm64`).

> Method note worth keeping: the first attempt at the spec→code sweep reported
> nothing, twice, and the clean result was false. The shell here is **zsh**,
> which splits `$(command)` but *not* `$var` — so `for s in $syms` passed the
> whole symbol list to `grep` as one multi-line pattern, which matched
> everything. A sweep that returns "all clean" on the first run deserves a
> deliberate negative control before it is believed. That is how R7-1 surfaced.

---

## G1 — the GUI pass (2026-08-01, round 7)

**G1 is now PARTIALLY CLOSED, and the boundary matters more than the headline.**
`MuseUITests/MuseSurfaceDriveTests.swift` drives the real app through XCUITest —
10 tests, all green — and every surface below was confirmed by *looking at the
screenshot*, not by the test going green.

Two things made this possible after it looked blocked. XCUITest gets automation
rights through the test runner, so it does **not** need the terminal to hold
Automation/Accessibility TCC permission (osascript does, and is refused). And
`MuseUITests` was three Xcode template stubs asserting nothing — "6 UI tests
passing" had meant nothing at all.

### Confirmed by screenshot

| Surface | What was actually seen |
|---|---|
| Launch / DB / migrations | Sidebar populated from real rows: folders with counts, 1,915-file folder, 10 collections |
| Hero viewer | Opens on **double-click**, closes on Escape (asserted on "Zoom out", a hero-only control) |
| **Editor (Spec 04)** | Full panel: Exposure→Noise Reduction sliders, Light/Color/Looks tabs, undo/redo, before/after, Reset |
| **Readouts (Spec 05)** | Tone Zones strip, Zone Sliders, **Curve with a live histogram**, and the teaching copy computing a real value: "1.2% of pixels are clipped — those areas have lost detail" |
| **Compare (Spec 03)** | Two panes, per-pane file tabs, Fit/1.0× zoom, focus indicators, active pane outlined |
| ~~**Cull (Spec 03)**~~ | Feature REMOVED 2026-08-02 (owner call) — nothing left to drive. |
| Duplicates (P8) | Modal opened and listed a **real** duplicate pair from the library |
| Import ×5 (Spec 06) | All five entries open their panel with correct, localized prompts |
| Backup (P19/Spec 09) | Save panel with correct default `Muse Backup 2026-08-01.muselibrary` + guidance copy |
| Settings | Opens with real controls ("Automatic organization", "Corner Radius") |
| Escape handling | Every modal above closes on Escape — a standing regression test for round 1's F16 |

### Still NOT verified — do not read the table above as more than it says

- **Feature correctness.** These prove surfaces OPEN and RESPOND. No slider was
  moved and no render output was compared; the editor was opened, not *used*.
- **Social export, Drive publish/portfolio.** Need network and an OAuth session.
- **Restore from backup, delete.** Deliberately excluded — they mutate user data.
- **Import execution.** The panels open; no import was actually run to completion.
- **The general export card (P29).** The renderer beneath it is pinned by 68
  tests against real files. `MuseUITests/MuseExportDriveTests` now automates the
  parts a unit test can't see — that the card opens IN FRONT of the hero viewer
  and the editor (it didn't; that was review finding one), that typing a size
  commits, that the estimate resolves to a real number, that the dropdown offers
  the formats and no longer offers the cut platforms, and that a social preset
  states its output size.

  **Ran 2026-08-02, all seven green.** Two lessons from the first run, both
  about the TEST rather than the app.

  A locked screen blocks the whole UI target. Every XCUITest fails at runner
  init with `LocalAuthentication Code=-4 "System authentication is running."`,
  which reads like a stray dialog and isn't — it's the login window, confirmed
  by `CGSSessionScreenIsLocked = 1`. Killing `coreautha` does nothing; that
  agent only presents what the lock screen asks for. No GUI verification is
  possible remotely on a locked Mac, full stop.

  Then three of seven failed on the first real run, and none of the three meant
  the app was broken. Rows built with `.accessibilityElement(children:
  .combine)` — the estimate and the social size row — publish ONE element whose
  *value* is the merged `"Est. file size, ≈128 KB"`, so
  `staticTexts["Est. file size"]` finds nothing. Combining is right for
  VoiceOver, so the assertions moved to matching on element values.
  `ExportModelEstimateTests` was added to settle it: it drives `ExportModel`
  directly and proved the estimate chain was fine before any test was touched,
  which is the check that stops "fix the test until it passes" from hiding a
  real fault.

  The card also deliberately stops SHORT of pressing Export: that opens the
  sandbox powerbox folder panel, which is out-of-process and unreliable to
  drive. The bytes on the far side of it are covered by
  `ImageExportRenderTests`, which writes and reads back real files.

  What still wants a human, in the order a person would do it:
  1. Grid, right-click one image ▸ **Export…** — the dropdown shows **Format**
     above **Social**, with `Same as original` first.
  2. Pick **JPEG**, drag Quality, set **Long edge** to 1200, Export, choose a
     folder. One file lands, 1200px on its long edge, named after the source.
  3. Export the same file again into the same folder — the second lands as
     `<name>-2.jpg`. **The first is not overwritten.** This is the rule that
     matters most; everything else here is a convenience.
  4. Right-click a **RAW** ▸ Export… ▸ `Same as original`. The advisory reads
     *"RAW can't be written back — this exports as JPEG."* and a JPEG appears.
     **This is the gap the whole feature exists to close.**
  5. Select several images, Export… — the pager appears, the progress bar runs,
     and the count of files written matches the selection.
  6. Open a photo ▸ **Edit**, change something, then the share button ▸ Export…
     The exported file carries the edit.
  7. **TIFF ▸ 16-bit** on an *edited* photo shows the 8-bit advisory; on an
     unedited one it does not.
  8. **Save Settings as Preset…**, name it — it appears under **My Presets**,
     survives a relaunch, and selecting it restores every control including the
     size fields.
  9. A **Social** preset still crops, mattes and exports exactly as before. This
     is the regression check on splitting the card in two.

### Two method lessons, both from this suite's own bugs

1. **The first hero test PASSED while doing nothing.** It pressed Return (which
   only selects — `handleTileTap` opens on double-click) and asserted "the window
   exists", which is true whether or not anything opened. It now asserts on a
   hero-only control. A UI test whose assertion cannot fail is the same defect
   class as the grid cull badge that this branch shipped unbuilt.
2. **The first compare test blamed the app for a driving bug — twice.** It
   reported "Compare stayed disabled after selecting two tiles" when the real
   cause was first cmd-clicking the already-selected tile (toggling it off), and
   then clicking a masonry *gap* (clearing the selection). Screenshots settled
   both. On a ragged grid, click tile CENTRES measured from a real screenshot.

---

## Round 7b — the tag chip row, and what strengthening the tests found

### R7-4 (perf) — the tag chip row re-measured every chip on every hover frame

`ChipFlow` is a custom SwiftUI `Layout` over the **whole** chip set, and both
`sizeThatFits` and `placeSubviews` independently called
`subviews.map { $0.sizeThatFits(.unspecified) }` — a full text-measurement pass
per chip, twice per layout pass. The row is neither capped (no `LIMIT` in
`TagChipLoader`, no `prefix` in the view) nor lazy, and `hovered` is animated
(`.easeOut(duration: 0.18)`), so one hover ran that measurement on the order of
2 × ~11 frames × n chips. On the dev library n is **196**, laid out to x≈17,500
in a 1,202pt window; sweeping the mouse along the row made it continuous.

**Fix:** `Layout`'s own `Cache`. Natural widths are hover-INDEPENDENT by design —
the no-reflow behaviour redistributes growth between neighbours rather than
remeasuring, and the count that appears on hover is drawn in an `.overlay`,
which does not affect intrinsic size. So widths are measured once per chip SET
and reused across hover frames. `updateCache` re-measures only when a
`ChipIdentityKey` fingerprint (label + count — exactly what changes a chip's
width) differs, since the default implementation re-runs `makeCache`
unconditionally and would give back the entire saving.

`ChipIdentityKey` is `nonisolated`: `Layout`'s methods are nonisolated, and a key
carrying SwiftUI's default main-actor isolation warns today and fails to compile
under the Swift 6 language mode. The Release build stays warning-free.

**Not done, deliberately:** capping the chip count is a product change (tags
become unreachable from the row), and `LazyHStack` is incompatible with the
no-reflow math, which needs every chip's width. The row is still O(n) per
layout pass — this removes the expensive constant, not the complexity class.

Guarded by `MuseUITests/MuseTagChipRowTests`: chips never overlap, chips
re-measure after a folder switch (the staleness case a cache introduces), and
the row's span is stable across hover.

### Two test defects this round, both mine, both instructive

**A test asserted the opposite of a documented deviation.** Strengthening the
cull test to check that Escape dismisses the HUD failed — and the app was
right. Spec 03 **deviation D8** deliberately keeps the cull session out of the
Escape chain: a pass holds keep/reject marks, so "an accidental Escape/misclick
must not silently discard an hour of marking"; only Finish/Cancel end it. The
test now GUARDS D8 rather than contradicting it. Check the spec before believing
a strengthened assertion that suddenly fails.

**A "regression" that was a measurement artifact.** The hover test first
asserted on the leftmost chip's absolute `minX` and reported a 10pt no-reflow
regression from the cache. It was the scroll: `hover()` makes XCUITest scroll
the target into view, translating every chip. Acting on it, an entire
lazy-cache-fill workaround was written for a bug that did not exist. With a
translation-invariant assertion (row SPAN), the simple eager `makeCache` passes,
and the workaround was reverted. **A perf change that appears to alter rendering
deserves a baseline run on the unmodified code before the cause is theorised** —
that baseline is what exposed this.

Third, smaller: asserting one shared "Import" button across all five import
sources produced two false failures. `AppState+Import` sets "Import", "Import
Here" or "Choose Library" depending on what each panel asks for; the test is now
per-source.


---

## HDR runtime plan (2026-08-03) — OPEN

No test can confirm an HDR photo *looks* right; the suite can only prove values
above 1.0 survived each stage. Everything below needs eyes on an EDR display,
and none of it has been done.

**Setup.** Build Release, **`stat` the binary's mtime** before looking at
anything (an incremental build can print BUILD SUCCEEDED over a weeks-old
`.app`), and quit all but one Muse instance. Use a real iPhone gain-map HEIC —
the fixtures are synthetic PQ files, which exercise the code but are not what
a user owns.

| # | Step | Pass condition |
|---|---|---|
| 1 | Open a folder holding a gain-map HEIC | The tile renders; highlights show EDR brightness |
| 2 | Open the photo into the hero | **The tile and the hero match** — no brightness jump on open. This is the whole reason the grid was in scope |
| 3 | Nudge Exposure in the editor | The photo does **not** flatten. Before this work it went SDR the instant a stack existed |
| 4 | Watch the histogram on a correctly-exposed HDR frame | No "those areas have lost detail" over ordinary specular highlights |
| 5 | Export as PNG | Highlights rolled off, not blown to flat white |
| 6 | Export as HEIC (macOS 15+) | Output still HDR, and still looks right when opened on a non-HDR display |
| 7 | Export unedited as "Same as original" with metadata kept | Byte-identical to the input (this one IS covered by `ImageExportHDRTests`) |
| 8 | Second launch after the update | Tiles regenerate once (the `cacheFormatVersion` bump) and then load from cache |

**macOS 14.6 cannot be checked on the development machine.** The `#available`
branches are shaped so the 14.6 path is the code the app already ran (SDR),
which bounds the risk to a compile/availability error rather than a behavioural
one. The Reinhard fallback WAS exercised, by forcing the branch on this machine
— and that is how its normalization bug was found, so the technique is worth
repeating for any future 14.6-only path.

## The drive suite is BLOCKED on this machine (2026-08-03) — OPEN

`MuseSurfaceDriveTests` / `MuseExportDriveTests` are the evidence behind G1's
"partially closed". **They cannot run right now**, and it is not a branch
regression: `testAppLaunchesWithPopulatedSidebar` — untouched since round 7 —
fails identically.

What the runner sees:

| Signal | Value |
|---|---|
| `app.state` | 4 (`runningForeground`) |
| `app.windows.count` | **0** |
| `app.dialogs.count` | 1 — the main window, published with the Dialog type |
| `app.buttons.count` | 268, every grid tile labelled with its filename |
| Every element | marked **Disabled**, so nothing is `isHittable` |
| Screen during the run | Muse owns the menu bar; **no Muse window is drawn** |

Launched by hand from the same build the app is completely normal (screenshot
taken the same minute). So the app is fine and the harness is not: the window
never becomes visible when XCUITest launches it, and AX reports the whole tree
disabled behind a Dialog. Machine is macOS 26.5.2 (25F84).

Consequences, until this is understood:

* **Every "confirmed by screenshot" claim below is as of 2026-08-02.** Nothing
  has been re-confirmed since.
* The ⌘U assertions added to `testEditorZoomAndHideControls` on 2026-08-03 have
  never executed. The shortcut is unverified at runtime.
* Do NOT "fix" this by loosening the window lookup to accept a dialog. That
  would make the suite green against an app whose window is not on screen —
  the exact vacuous-pass failure this suite was built to avoid. Find out why
  the window doesn't appear first.
