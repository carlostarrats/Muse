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

Last full pass: **2026-08-01** (review round 2). Suite at that point:
**1,783 tests, 2 skipped, 0 failures**.

---

## Standing gaps (read first)

These are true across many rows and are not repeated in each one.

| # | Gap | Status |
|---|---|---|
| G1 | **Almost nothing on `new-product-build-1` has been driven in the running GUI.** Launch, migrations and the backfill chain were confirmed with `MUSE_TRACE=1` against the real library (review round 1, Pass C). The editor, compare/cull, all five import sources, social export, Drive publish/portfolio and backup/restore have not been. | **OPEN** — needs hands, not another review |
| G2 | **Backup does not carry edit data.** `BackupOccurrence` has no edit fields, so a restore loses every edit stack. Deliberate today (backup restores originals by content hash); Spec 09 amendment A2 closes it. | **OPEN — by design pending Spec 09** |
| G3 | `files_fts.file_id` is `UNINDEXED`, so any `WHERE file_id = ?` against it is a full FTS scan. Callers are chunked to make it cheap; fixing it properly means rebuilding the FTS table in a migration. | **ACCEPTED** |
| G4 | `RediscoveryQueries.onThisDay`'s no-`photo_meta` fallback filters on `strftime` over `files.created_at` and cannot use an index. Set shrinks toward zero as the header backfill completes. | **ACCEPTED** |
| G6 | **~60 Swift 6 strict-concurrency warnings**, mostly `TagScope.parentDir` / `ImageHeaderSizeCache` being `@MainActor` while called from `nonisolated` DB and decode paths. Pre-existing and project-wide, not introduced by this branch. Benign under the Swift 5 language mode the app builds with; every one becomes a hard error if the target ever moves to Swift 6. The genuine race in the set (`SearchService`'s captured `var colorQuery`) was fixed in round 2. | **ACCEPTED** — a Swift 6 migration is its own project |
| G5 | Distribution is still **direct + Sparkle**. The StoreKit plumbing in `Commerce/` is inert scaffolding; the Mac App Store move is deferred (`docs/superpowers/plans/deferred-mac-app-store-migration.md`). | **DEFERRED** |

**Closed since round 1:** the 146 untranslated French keys (G-loc) — the catalog
is now **1,002 keys, 0 untranslated**.

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
| P8 | Duplicate finder + delete-to-trash | `DuplicateDeleteRulesTests`, `DeleteCoordinatorTests`, `TrashManagerTests` | 2026-08-01 | ⚠️ G1 | ✅ distinct from Spec 02 near-dup **stacks**; no shared state |
| P9 | Grid virtualization + masonry | `MasonryGeometryTests`, `UniformGridLayoutTests`, `JustifiedRowsGeometryTests`, `GridSpacingTests` | 2026-08-01 | ⚠️ G1 | ✅ still virtualized — cull badge passed as a parameter, `CullStore` observed **once** |
| P10 | Grid selection, keyboard nav, page scroll | `GridSelectionTests`, `GridKeyboardNavTests`, `PageScrollTests`, `GridScrollRevealTests` | 2026-08-01 | ⚠️ G1 | ⚠️ **was broken, fixed R1-F16** — 5 new modals gated the key catcher with no Escape branch |
| P11 | Hero viewer (flight, zoom/pan, wash) | `ViewerGeometryTests`, `HeroPaletteTests`, `ImageHeaderSizeCacheTests` | 2026-08-01 | ⚠️ G1 | ⚠️ **fixed R2-1** — flight take-off rect used uncropped dims on a cold header cache |
| P12 | Thumbnails + decode budget | `ThumbnailVariantTests`, `ThumbnailStackKeyTests`, `ThumbnailWriteTests`, `DecodePermitTests`, `VisionDecodeTests` | 2026-08-01 | ✅ launch trace | ✅ unedited key byte-identical to pre-Spec-04 — no library re-keys on upgrade |
| P13 | QuickLook exclusion (video **and** audio) | `QuickLookExclusionTests`, `AudioArtworkTests` | 2026-08-01 | ⚠️ G1 | ✅ `mayUseQuickLook` still the single predicate; no new AV entry point bypasses it |
| P14 | AV no-network (`rmra`/`rdrf`) | — (enforced by construction) | 2026-08-01 | ⚠️ G1 | ✅ **verified: zero bare `AVURLAsset(url:)`/`AVPlayer(url:)` in the tree.** Spec 02's new `PhotoHeaderReader` uses the restricted helper |
| P15 | SVG viewer no-network (`WKContentRuleList`) | — | 2026-08-01 | ✅ (v1.5) | ✅ rule-list + deferred load + fail-closed all intact |
| P16 | Housekeeping prune (fail-closed) | `HousekeepingTests` | 2026-08-01 | ⚠️ G1 | ✅ root-visibility guard + `icloudRoot` param intact |
| P17 | Path reconcile by existence (fail-closed) | `PathReconcilerTests` | 2026-08-01 | ⚠️ G1 | ✅ `rootReachable` gate intact, still fire-and-forget |
| P18 | iCloud sidecars + hydration | `SidecarTests`, `SidecarStoreTests`, `EditSidecarTests`, `SidecarHydrateRatingTests` | 2026-08-01 | ⚠️ G1 | ⚠️ **fixed R2-4** — see P2. Sidecars now carry edits (Spec 04) with their own field clock |
| P19 | Backup / restore / reconnect | `BackupArchiveTests`, `BackupBuilderTests`, `ReconnectMatcherTests`, `ReconnectApplierTests`, `CollectionMaterializerTests` | 2026-08-01 | ⚠️ G1 | ✅ **no schema regression** — every v13–v23 `ADD COLUMN` is nullable, so restore still writes. ❗ G2 stands |
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
| S02.2 | Offline reverse geocoding + Places page | `ReverseGeocoderTests`, `GeoKDTreeTests`, `GeoNamesDatasetTests`, `PlaceQueriesTests` | 2026-08-01 | partial | No per-photo network — verified |
| S02.3 | Rediscovery (On This Day / Rarely Seen / Shuffle) | `RediscoveryQueriesTests`, `SeededRandomTests` | 2026-08-01 | ❌ G1 | G4 |
| S02.4 | Near-duplicate stacks + bursts | `AutoStackerTests`, `BurstClustererTests`, `StackStoreTests`, `StackDisplayTests`, `StackScatterTests` | 2026-08-01 | ❌ G1 | Distinct from P8 duplicates |
| S02.5 | Phase-1 token search + `.location` rule | `SearchTokenFacesTests`, `SmartRuleLocationTests`, `NLTokenComposerTests` | 2026-08-01 | ❌ G1 | |
| S03.1 | CLIP engine / index / model store | `ClipIndexTests`, `ClipVectorsTests`, `ClipPreprocessTests`, `ClipModelManifestTests`, `EmbedderTests`, `ClipMigrationTests` | 2026-08-01 | partial | Keyset-paged + bounded top-K (R1-F8) |
| S03.2 | On-demand model download | `SandboxProcessTests`, `ClipModelManifestTests` | 2026-08-01 | ✅ exec pinned | Fail-closed ladder; SHA-256 before unpack |
| S03.3 | `is:` / `faces:` / `pets:` / `similar:` tokens | `SearchTokenFacesTests`, `PhotoSearchTraitsTests`, `PhotoSearchSimilarTests`, `SimilarTermTests` | 2026-08-01 | ❌ G1 | |
| S03.4 | Compare workbench + focus peaking | `CompareCullTests`, `PeakingOverlayTests`, `SharpnessScoreTests`, `PortraitHeuristicTests` | 2026-08-01 | ❌ G1 | ⚠️ **fixed R2-3** (VoiceOver) |
| S03.5 | Ephemeral cull + grid badge | `CompareCullTests` | 2026-08-01 | ❌ G1 | ⚠️ badge **was never built**, added R1-F23 |
| S03.6 | NL suggestions | `SearchSuggestTests`, `SearchSuggestTraitsTests`, `NLTokenComposerTests` | 2026-08-01 | ❌ G1 | |
| S04.1 | Edit model + codec + history | `EditStackCodecTests`, `EditStackNormalizeTests`, `EditHistoryTests`, `EditMigrationTests`, `GeometryParamsTests` | 2026-08-01 | ❌ G1 | Canonical hash pinned by literal fixture |
| S04.2 | Render chain (Core Image / Metal) | `EditRenderConsistencyTests`, `EditRenderNeutralityTests`, `EditKernelLoadTests`, `RenderCoalescerTests`, `CurveLUTTests`, `HighlightRecoveryTests` | 2026-08-01 | partial | RAW `scaleFactor` fixed R1-F3; non-RAW half **disproved** by measurement |
| S04.3 | `EditStore` + live provider + consumer sweep | `EditRecordStoreTests`, `EditStackIndexTests`, `EditSessionTests` | 2026-08-01 | ❌ G1 | ⚠️ **fixed R2-2** — persisted a translated version name |
| S04.4 | Editor UI (curve, WB, before/after, versions) | `EditSessionTests`, `CanvasPointMathTests`, `MiredMappingTests` | 2026-08-01 | ❌ **G1 — highest-value gap** | |
| S04.5 | Presets, copy/paste, Edit-a-Copy | `EditPresetStoreTests`, `EditCopyNamingTests`, `EditTransferTests` | 2026-08-01 | ❌ G1 | |
| S05.1 | Teaching histogram + clipping copy | `HistogramComputeTests`, `ClippingMessagesTests` | 2026-08-01 | ❌ G1 | |
| S05.2 | Tone-zone control + overlay | `ToneZoneMathTests`, `PhotoStatsQueriesTests`, `PhotoStatsMigrationTests` | 2026-08-01 | ❌ G1 | |
| S05.3 | "Why it looks this way" (deterministic) | `PhotoFeedbackTests` | 2026-08-01 | ❌ G1 | |
| S05.4 | `.cube` LUT import + registry | `CubeLUTParserTests`, `LutRegistryTests`, `LutStoreTests`, `EditLutMigrationTests` | 2026-08-01 | ❌ G1 | LUT read is off-main (R1-F6) |
| S05.5 | Looks browser + reference pane | — (UI) | 2026-08-01 | ❌ G1 | Single decode reused across cells |
| S06.1 | One File > Import surface (5 sources) | `ImportPureTests`, `MetadataImportApplyTests`, `MetadataImportRulesTests`, `MetadataKeywordReaderTests` | 2026-08-01 | ❌ G1 | Re-run idempotency verified statically at every leg |
| S06.2 | Lightroom `crs:` edits + presets | `LightroomImportTests`, `XPresetRuleTests` | 2026-08-01 | ❌ G1 | |
| S06.3 | Color-label namespace + mapping sheet | `MetadataImportRulesTests` | 2026-08-01 | ❌ G1 | |
| S06.4 | Throttle / analysis status / import FYI | `WorkProgressTests`, `LaunchBackfillQueryTests` | 2026-08-01 | ✅ trace | Throttle now scales concurrency, not just pause (R1-F4) |
| S07.1 | Manifest v2 + three page layouts | `DriveShareManifestTests`, `SocialPresetTests` | 2026-08-01 | ❌ G1 | Page tests pass (`web/share/share.test.mjs`) |
| S07.2 | Portfolio mode (stable URL, live manifest) | `DriveShareStoreTests` | 2026-08-01 | ❌ G1 | Upload → atomic swap → sweep, rollback before swap |
| S07.3 | Social export card + render ladder | `SocialRenderTests`, `SocialCropMathTests`, `SocialMetadataTests` | 2026-08-01 | ❌ G1 | ⚠️ crop stage previewed the unedited original — fixed R1-F18 |
| — | Migration chain v13→v23 | `MigrationChainTests` + 8 per-migration files | 2026-08-01 | ✅ replayed on real data | Pure DDL, O(1) at launch, endpoint pinned at v23 |

---

## Review rounds

| Round | Date | Scope | Findings | Suite after |
|---|---|---|---|---|
| 1 | 2026-08-01 | Specs 01–07, ten sweeps / eight slices (`REVIEW-FINDINGS.md`) | 23 fixed (F1–F23) | 1,775 |
| 2 | 2026-08-01 | Regression of pre-branch features under this branch's seams, + lenses round 1 didn't run | 4 fixed (R2-1…R2-4) | 1,783 |

### Round 2 findings

| # | Severity | Finding | Fix |
|---|---|---|---|
| **R2-1** | med | **`EffectiveDimensions.resolve` returned UNCROPPED dimensions on a cold header cache.** It asked for the crop first, but `EditStackIndex.croppedSize` scales the crop against `ImageHeaderSizeCache.cached` — a no-I/O lookup that answers nil until something warms it. Both callers (the Info card's dimensions row, the hero flight's take-off rect) document that they want the post-crop size. The grid's masonry path had the same shape, and worse: it marked the path `resolved`, so only the visible-tile `report` backstop could ever correct it. | Resolve the header FIRST, then ask for the crop. In `AspectRatioCache` the warm-up is gated on the file actually carrying an edit, so the cost is bounded to a rare case. |
| **R2-2** | low | **A translated string was persisted to the database.** `EditStore.switchToVersion` auto-preserves the outgoing stack under `String(localized: "Previous")`, writing "Précédent" into `edit_versions.name` on a French system — against the app-wide "storage stays canonical-English, localize at display" rule that every other Muse-derived label follows. | `EditVersionName`: canonical `"Previous"` stored, localized at display. User-typed names pass through untouched. |
| **R2-3** | med | **Compare's two primary actions were unreachable under VoiceOver.** Rating (0–5) and cull marking (K/X/U) are handled by `CompareKeyCatcher`, and VoiceOver swallows plain character keys before an `NSView` sees them. Exactly the gap round 1 fixed for the grid's cull marks — the same reasoning, one surface further on. | Named accessibility actions per pane (rate 1–5, clear rating; keep/reject/clear while a cull session is running). |
| **R2-4** | **high** | **An edit save could wipe another device's synced tags.** `Sidecar.resolveForWrite`'s non-merge path takes tags from `fresh` wholesale — right for a *tag* edit, wrong for the edit-save export, which uses the same path. A device that hasn't hydrated a sidecar yet has those tags in neither its DB nor `fresh`, so saving an edit rewrote the sidecar's tag list without them. The same hazard is already guarded for `note` and `edit_stack` on that exact write. | `tagsAuthoritative` parameter; the edit export passes `false` and tags UNION instead (single-rating resolution preserved). +4 tests. |

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

---

## Maintaining this ledger

- A new feature gets a row **in the same PR that builds it**, with `R` set to ❌ until someone drives it.
- A review round appends a section above and updates the state columns it actually established.
- When G1 is closed, the ❌/⚠️ marks in the **Runtime** column are what needs walking — that list is the GUI test plan, already written.
