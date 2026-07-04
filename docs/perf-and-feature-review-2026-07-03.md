# Muse — Performance & Feature Review Handoff (2026-07-03)

Self-contained brief for a fresh AI session. Source: two read-only code surveys
of the full codebase (grid/thumbnails/indexing/DB/AppState/Vision/search +
feature inventory), synthesized 2026-07-03 on `main`-equivalent state
(branch `feat/next-115`, clean).

**How to use this doc:** pick ONE item, read its file:line anchors and the
guardrails section before editing, implement, run `xcodebuild -scheme Muse test`
(keep 503+ unit tests green), and verify in the running app per the repo's
"verify runtime, not just tests" rule. CLAUDE.md's "Durable constraints &
gotchas" section is binding — read it first.

---

## Part 1 — Performance findings (ranked by real-world impact, 1k–20k images)

### P1. Clustering is O(n²·d) brute force, re-run after every analyze pass — HIGH · **DEFERRED**
- **Status (2026-07-03): DEFERRED — theoretical for this persona.** The n²
  cost only bites a *large analyzed* library (~20k AI-embedded images) that
  actively uses auto-collections; the generalist persona (Downloads/Documents
  management, AI opt-out and not the front door) rarely reaches that scale.
  It is also the highest-risk item here to change — recluster + the
  `setHidden` tombstone semantics are test-pinned and the real fix is an
  algorithm swap. Do NOT do it speculatively; wait for an actual stall on a
  real large library. P3 (vDSP cosine) lands first regardless and makes this
  cheaper for free.
- `HybridClusterer.cluster` (`Core/HybridClusterer.swift:19–24`) does all-pairs
  cosine over every non-screenshot embedding.
- `CollectionsEngine.recluster` (`Collections/CollectionsEngine.swift:109–126`)
  loads **all** embeddings via `EmbeddingRow.fetchAll` and runs it after *every*
  analyze pass (`Intelligence/AnalyzePipeline.swift:251`).
- Cost: ~2×10⁸ pairs at 20k images × ~512-dim vectors ≈ 10¹¹ float ops per
  recluster; quadratic growth. Runs detached, but the trailing `reload()` is
  @MainActor and the whole thing gates the analyze pipeline.
- Direction: incremental clustering (new embeddings vs existing centroids),
  or ANN/LSH prefilter; debounce/cap recluster frequency.
- Guardrails: collection "delete" is `setHidden(true)` tombstones the recluster
  must never clear. Collection identity/membership behavior is pinned by
  `MuseTests` (collection identity + naming tests).

### P2. Semantic search re-fetches + re-scores every embedding per query — HIGH · **DEFERRED**
- **Status (2026-07-03): DEFERRED — theoretical for this persona; does NOT get
  harder over time.** Same gate as P1: only bites a large *analyzed* library
  (~20k embeddings) where semantic search is used heavily; below that the cost
  is imperceptible, and it's skipped entirely when there are no embeddings
  (`SearchService.swift:66`, `queryVector ?? []`). Unlike P1 the cost is *felt
  latency* (it's on the search critical path, not invisible background waste)
  — but still off-main (`semanticIDs` is `nonisolated`) and only at scale.
  **Safe to defer:** the fix is additive and its hook is stable — embeddings
  have exactly ONE write site (`AnalyzePipeline.swift:461`), so a warm-matrix
  invalidation + normalize-on-write is a one-liner there now or later; a bigger
  library only lengthens a one-time migration backfill, it doesn't make the fix
  harder. **Most of the value is front-run by P3** (vDSP cosine — cheap,
  contained, and it speeds up BOTH `fetchAll` sites: this one and P1's
  clusterer). The expensive "warm matrix + pre-normalize" tier adds a cache to
  invalidate + a data-format migration for no felt benefit until real scale.
  Flip condition: routinely searching a ~15–20k analyzed library. Do P3 first
  regardless — it's also the diagnostic that reveals whether P2 is even needed
  (if search is still slow after P3, the residual IS the fetchAll/deserialize).
- `SemanticSearch.semanticIDs` (`Core/SemanticSearch.swift:30–33`) runs
  `EmbeddingRow.fetchAll(db)` and cosines the query against every stored vector
  on each committed search (`SearchService.swift:66`).
- Cost: per search, ~20k BLOB→[Float] deserializations + ~10M float ops.
- Direction: warm in-memory Float matrix (invalidate on embedding writes);
  pre-normalize vectors at write time so scoring is a single dot product.

### P3. `VectorMath.cosine` is a scalar Double loop — HIGH (amplifies P1+P2) · **APPROVED**
- **Status (2026-07-03): APPROVED — do it (queued into the spec/implementation
  batch, not yet built).** Chosen for the *always-on* CPU/battery saving during
  background clustering — the clusterer (P1's path) runs after every analyze
  pass at any moderate library size, so a vectorized cosine cuts real
  background CPU even though P1/P2's *search* payoff is deferred-scale; that
  power-user battery benefit is the motivation. It's also the cheapest +
  lowest-risk item on the list: one self-contained function, only two callers
  (`HybridClusterer.swift:21`, `SemanticSearch.swift:32`) so NO signature
  change, and the existing `EmbedderTests.testCosine` survives (tolerant 1e-6
  cases). Numerical risk is immaterial (Float vs Double accumulation differs
  ~1e-6; the `0.62` clustering / `0.45` search thresholds are coarse — a
  borderline pair flip is measure-zero and quality-neutral). Impl direction:
  `vDSP_dotpr` (a·b) + `vDSP_svesq` (Σa², Σb²) over the Float32 arrays, final
  divide/sqrt in Double. TDD: strengthen the cosine equivalence test on a
  non-trivial vector FIRST, then swap the body.
- `Core/VectorMath.swift:4–14` iterates element-by-element, converting each
  Float to Double. This is the inner loop of both P1 and P2.
- Direction: Accelerate (`vDSP_dotpr` / `cblas_sdot`) over Float32 arrays.
  Likely the best effort-to-payoff item in this list; do it before or with
  P1/P2.

### P4. Folder open issues one read transaction per file — HIGH · **APPROVED**
- **Status (2026-07-03): APPROVED — do it (queued into the spec/implementation
  batch).** The strongest user-facing perf win on the list: runs on every fresh
  folder open, is **AI-INDEPENDENT** (hits any large folder, not just analyzed
  libraries), and its trigger scale (a 10–50k-file Downloads/archive folder) is
  realistic for the generalist persona — unlike P1/P2's "20k analyzed images."
  Off-main (`Task.detached`, `AppState+Indexing.swift:37`) so no UI freeze, but
  the 20k sequential DB transactions gate thumbnail prewarm + analysis
  (`:44`→`:56/:60`) and contend with grid reads on the serial GRDB queue. Fix:
  one chunked `IN (...)` fetch of (path,size,mtime,hash) per folder, diff in
  memory (~25 reads vs 20k, ~800× fewer transactions). MUST replicate the
  per-file decision matrix EXACTLY — iCloud (`isUbiquitous`) trusts the stored
  hash and ignores size/mtime; local requires an exact size+mtime match;
  missing `content_hash` → re-hash; batch the `last_seen>86400` touch
  (`Indexer.swift:528–533`) into one write; dataless-skip stays a per-file FS
  check. Guarded by `IndexerReconcileTests` + the CLAUDE.md iCloud content-hash
  rule; add direct `isUnchanged` decision-equivalence tests (TDD) since it is
  likely untested today.
- Discovery loop in `Indexer.swift:568–586` calls `isUnchanged` per file; each
  call (`Indexer.swift:509`) opens its own `queue.read` with two queries
  (PathRow then FileRow).
- Cost: a fully-indexed 20k-file folder pays ~20k sequential read transactions
  (~40k queries) on the serial GRDB queue on every open — delays prewarm/
  analyze and competes with UI reads.
- Direction: one chunked `IN (...)` fetch of all known (path, size, mtime,
  hash) for the folder, diff in memory.
- Guardrails (critical): the size/mtime fast-path is LOCAL-ONLY — iCloud paths
  deliberately use content hashing (size/mtime oscillate; see CLAUDE.md
  "iCloud change detection"). The batched version must preserve the exact
  same per-file decision logic, including dataless-skip and the zero-byte-hash
  guard in `HashService.sha256`. `IndexerReconcileTests` pins reconcile
  semantics (shared-row split on edit, membership carry) — do not disturb.

### P5. Vision analyze pass is strictly serial per file — HIGH (first-run throughput) · **DEFER — PENDING MEASUREMENT**
- **Status (2026-07-03): DEFER — pending measurement; do NOT build until
  measured.** The theoretical parallel-Vision speedup is capped by an unknown:
  whether the Neural Engine (which runs the dominant `tagger.analyze` stage,
  `AnalyzePipeline.swift:343`) is already saturated per image — if so, N-wide
  concurrency just queues on the ANE and wins little. Benefit is narrow anyway:
  first-run-only (incremental `analyzed_hash` gate), background, and
  NON-blocking (the folder is fully usable during analysis — only auto-tags/
  collections lag). **Measurement gate before ANY build, cheapest first:**
  (1) ZERO-CODE — run a real import of UN-analyzed images and watch Activity
  Monitor CPU (~1 core busy = idle headroom to win; most cores pegged = none)
  + Xcode Instruments "Core ML / Neural Engine" template (bursty ANE w/ gaps =
  win; saturated = no); (2) add debug per-stage timing to `analyzeOne` (Vision
  vs embed vs DB split), run one real import; (3) only if (1)/(2) look
  promising, a DISPOSABLE 2–3-wide task-group spike timed vs serial, then
  revert. **Decision rule:** idle cores / gappy ANE → promote to DO with a
  measured expectation; pegged cores / saturated ANE → defer PERMANENTLY
  (proven, not guessed). Risk if ever built: concurrency MUST live inside ONE
  `acquirePass()` claim (`:86/:135/:164`), never multiple passes; `registry.
  tagger` concurrency-safety is UNVERIFIED. NB: the benchmark only measures
  anything on un-analyzed files (the gate skips done ones — point it at a fresh
  folder or force Regenerate).
- `AnalyzePipeline.analyze(folder:)` (`Intelligence/AnalyzePipeline.swift:238–246`)
  awaits `analyzeOne` one file at a time.
- Direction: bounded task group (2–4 wide) over files; keep DB writes
  serialized.
- Guardrails: `analyzeOne` captures content hash BEFORE Vision and commits
  nothing if it changed mid-pass — preserve per-file. Pass serialization goes
  through `acquirePass()` (synchronous claim flag) — concurrency must live
  INSIDE one claimed pass, never as multiple passes. Sidecar writes merge with
  on-disk sidecars (`mergeExisting: true`) — keep. Decode sites must keep the
  `ThumbnailCache.withinDecodeBudget` guard.

### P6. Path→fileID resolution is N+1 — MEDIUM/HIGH · **DEFER — bundle with P4**
- **Status (2026-07-03): DEFER standalone; BUNDLE WITH P4 if touching this
  area.** Real impact negligible: N = files-TO-ANALYZE (new/changed only, the
  `analyzed_hash` gate), NOT folder size, and the N path→id reads (`:224`,
  microseconds each) are dwarfed by the Vision work they precede (seconds/
  image) — a sub-second resolution ahead of a multi-minute pass. Not worth a
  dedicated effort. But it's the SAME `IN (...)` batching pattern as P4 (repo
  already has it in `CollectionStore.fileIDs`) and low-risk (pure read
  resolution; only invariant is the dedup-by-file-id at `:216–232`), so fold it
  into P4's implementation as a cheap tidy. Second site
  `exportSidecarsAfterTagEdit` (`:311–320`) is the same shape, small N
  (per-tag-edit) except on bulk tag ops.
  (`AnalyzePipeline.swift:221–234`); same shape in `exportSidecarsAfterTagEdit`
  (`AnalyzePipeline.swift:311–320`).
- Direction: single chunked `IN (...)` join up front — `CollectionStore.fileIDs`
  already demonstrates the pattern in-repo.

### P7. Every visible tile observes the AppState monolith — MEDIUM/HIGH · **DEFER — health-watch, opportunistic**
- **Status (2026-07-03): DEFER the refactor — standing HEALTH-WATCH item,
  address opportunistically.** Impact is real but BOUNDED (windowed ~50–100
  tiles) and mostly invisible on fast hardware; felt as churn on slower Macs /
  during iCloud-sync FSEvents storms (a debounced FolderStat recompute
  forwarded at `:570–571` re-evals every grid tile though tiles render no
  folder-stat). Key mitigation ALREADY in place: the tile thumbnail is `@State`
  (`GridView.swift:578`), so a re-eval is body-diff cost, NOT a re-decode — the
  expensive thing is insulated. Full fix (extract selection/hover into its own
  small observable; sidebar observes `folderStats`/`stars` DIRECTLY) is an
  architectural refactor with real risk: the forwards exist on purpose
  (`:564–567` — Pin/Unpin + counts must update the sidebar immediately), so
  RE-ROUTE that observation, don't delete it; keep `bookmarks.$roots`
  synchronous (`:562`, no `.receive(on:)`). Per the health-watch guidance,
  address when new grid/AppState work is already open — NOT a speculative
  refactor now. Cheapest isolated sliver (pre-check who else observes
  `folderStats` via AppState first): drop the `folderStats` forward so
  sidebar-count churn stops invalidating the grid.
  AppState has ~60 `@Published` properties (`Models/AppState.swift:30–494`) and
  forwards `folderStats.objectWillChange` + `stars.objectWillChange` into its
  own `objectWillChange` (`AppState.swift:568–571`).
- Cost: any selection click, the per-minute `autoMoodIsDay` tick, `tagsVersion`
  bump, or a debounced FolderStat recompute invalidates ALL visible tiles +
  the whole ContentView body. Bounded by windowing (~50–100 tiles) but
  constant avoidable churn. This is also the standing "health watch" item
  (heavy AppState/SidebarView files).
- Direction: split selection/hover state into a small observable or pass as
  plain values; let the sidebar observe folderStats directly instead of
  forwarding into AppState.
- Guardrails: `bookmarks.$roots` sink must stay synchronous (no `.receive(on:)`).
  Do not rebind per-keystroke controls to AppState (see CLAUDE.md TextField
  rule). Grid must stay virtualized — no new non-lazy containers over the full
  file set.

### P8. `GridView.visibleIndices` is an O(n) scan per scroll tick — MEDIUM · **SKIP — non-issue**
- **Status (2026-07-03): SKIP — effectively a non-issue, lowest priority.** O(n)
  but the constant is trivial — two `CGFloat` compares per tile (`:423`) — so
  even 20k tiles ≈ ~20µs per scroll tick, imperceptible, ~800× headroom under a
  16ms frame. The code comment (`:414–415`) already judged it "cheap enough to
  run every scroll tick" and is correct. Binary-search/per-column fix would
  optimize microseconds into nanoseconds for zero felt benefit + added
  complexity. Revisit only if profiling ever shows scroll-tick CPU as real at
  extreme (100k+) scale. (Reasoning from op-count, not benchmarked.)
  20k comparisons per scroll frame; cheap constant but on the hot path.
- Direction: per-column sorted frame lists + binary search, or a coarse row
  index.

### P9. This-Folder search re-enumerates the folder on disk per query — MEDIUM · **DEFER**
- **Status (2026-07-03): DEFER — legit but not urgent; if done, prefer the
  caching variant.** A This-Folder search `await`s a full `FolderReader.files`
  stat-walk (`:114–127`) before returning (`:129` combines ranked + extras), so
  results are gated on a folder enumeration per committed search — off-main (no
  freeze) but felt as latency on big folders, This-Folder scope only. The walk
  exists to find on-disk-but-NOT-yet-indexed files by basename (`:104–106`), a
  narrow freshness gap (indexing runs on folder open, P4). NB correction to the
  fix below: "rely on FTS basename rows" would LOSE not-yet-indexed discovery —
  better fix is to CACHE the folder listing per session, invalidate on FSEvents
  (kills the repeat walk, keeps freshness). Guardrail either way: every file
  kind keeps its basename `files_fts` row (covered-ids Set, NOT correlated
  `NOT EXISTS` → O(n²) hang). Priority: below P4/P3, above P6/P8.
  substring "extras" on each committed search.
- Direction: rely on the FTS basename rows (v9 backfill made them universal)
  or cache the listing for the session.
- Guardrails: every file kind must keep its basename `files_fts` row; the
  backfill's covered-ids Set approach exists because `files_fts.file_id` is
  UNINDEXED (correlated `NOT EXISTS` = O(n²) launch hang).

### P10. FolderStats re-walks the whole root subtree per FSEvents burst — MEDIUM · **DEFER**
- **Status (2026-07-03): DEFER — bounded, and the "proper" fix fights
  FSEvents.** `FolderStats.compute` (`:46–66`) is a full recursive subtree
  enumeration (per-file `resourceValues`) for SIDEBAR stats (count/size/latest).
  Runs off-main per DEBOUNCED burst, already capped at 2.0s maxWait
  (`StatRecomputeScheduler`) — worst case one ~20k-file walk every 2s during
  sustained iCloud sync: background CPU/IO churn, NOT a UI freeze, sidebar-only.
  The doc's fix ("incremental from FSEvent deltas") is harder than it reads:
  macOS FSEvents does NOT give reliable per-file deltas (coalesces + can flag
  MustScanSubDirs = "rescan, I lost track"), so incremental counts would DRIFT
  and still need a periodic full reconcile — medium effort + a correctness risk
  (wrong sidebar counts) for a bounded background cost the debounce+cap already
  tames. Keep the existing cap; revisit only if sync-time battery becomes a
  demonstrated problem. (FSEvents-delta claim is platform knowledge; didn't
  verify the watcher's event granularity.)
  (`Filesystem/FolderStat.swift:46–66`): full recursive enumeration of the
  root per debounced burst; iCloud sync churn triggers repeated full walks
  (maxWait forces flushes).
- Direction: maintain counts incrementally from FSEvent deltas.
- Guardrails: keep the 2.0s maxWait cap (`StatRecomputeScheduler`) — a pure
  trailing debounce starves under sustained events (shipped bug).

### P11. `CollectionStore.fetchAll` is N+1 per collection — MEDIUM · **SKIP — low impact**
- **Status (2026-07-03): SKIP — low impact, delicate target.** NOT a
  per-transaction N+1 like P4/P6: `fetchAll` (`:257–285`) runs `1 + 2×C`
  queries ALL INSIDE ONE `queue.read` (`:258`), C = number of collections
  (tens, rarely hundreds) — a few ms, not thousands of transactions.
  Negligible unless hundreds of collections. Fix is NOT a clean GROUP BY: the
  alive count filters DISTINCT alive paths UNDER ACTIVE ROOTS in SWIFT
  (`:273–275`, `isUnderAnyRoot`) — exactly Lever 1 of the "shows N but opens
  empty" fix ([[muse-collection-count-vs-contents-spec]], a documented past
  bug). Rewriting risks reintroducing it for a sub-ms saving. Skip unless
  hundreds of collections + felt reload latency.
  `reload()` fires on many mutations.
- Direction: one GROUP BY collection_id query for counts across all
  collections.
- Guardrails: reachability gating (`hasReachableContent` + `reachableFileCount`
  -1 sentinel) must keep its exact semantics — see CLAUDE.md "Collections
  visibility" constraint.

### P12. `Housekeeping.pruneUnreachable` full-table scan + N+1 — LOW (launch-only) · **SKIP**
- **Status (2026-07-03): SKIP — launch-only, candidate set ~empty, data-loss-
  critical.** `pruneUnreachable` (`:35–74`) runs ONCE at launch: full scan
  `WHERE last_seen_at < cutoff` (`:44`, 180d) then an N+1 paths query per
  candidate (`:50–62`), ALL in one `queue.write`. N = files unseen for 180 days
  — normally ZERO or a handful — so the N+1 never has meaningful N, and a
  single 20k-row scan at launch is ms. Join+index payoff is nil in practice.
  And this is a PERMANENT DELETE (`:65–73`) behind a fail-closed root-visibility
  + iCloud-protection gate (`:30–34`, `HousekeepingTests` pins it) — the
  documented data-loss minefield. Only defensible standalone: a purely additive
  `last_seen_at` index IF launch profiling ever flags the scan (premature now).
  Optimize query SHAPE only, NEVER the gating.
  paths query (`:50–62`).
- Direction: single join; optional index. Guardrail: this is a PERMANENT
  delete with a fail-closed root-visibility gate (`HousekeepingTests` pins it)
  — optimize the query shape only, never the gating.

### P13. Thumbnail PNG write round-trips TIFF→NSBitmapImageRep→PNG — LOW · **APPROVED**
- **Status (2026-07-03): APPROVED — do it (queued into the batch; pairs with P3
  as a cheap "efficiency" group).** NB the TIFF is NOT about the user's source
  files being TIFFs — `tiffRepresentation` is AppKit's generic in-memory bitmap
  serialization used for EVERY thumbnail write regardless of source format
  (JPEG/PNG/HEIC/RAW all hit it). So the win is source-format-agnostic: cuts
  wasted CPU + a ~1MB transient alloc whenever many thumbnails are GENERATED
  (prewarm / first open of a big folder), off-main so invisible but real
  battery. Fix: extract the `CGImage` from the `NSImage`, write via
  `CGImageDestination` (PNG UTType), skip TIFF. One function (`:420–424`), low
  risk (same PNG output + atomic write + failure guard; sanity-check
  color-profile equivalence). Only cuts the write-encode half of prewarm (the
  source decode/downsample is the other half).
- `ThumbnailCache.swift:420–425` (`writePNG`). Direction: `CGImageDestination`
  directly.

### Minor · **SKIP BOTH**
- **Status (2026-07-03): SKIP both — not worth doing.** (1) The hash-concurrency
  cap of 2 is a DELIBERATE anti-stutter throttle (`Indexer.swift:539–542`);
  raising it trades UI smoothness for cold-index speed = measure-first tradeoff,
  not a free win. (2) The `intent IS NOT NULL` scan is one query — negligible by
  the doc's own admission.
- `indexBatch` hash concurrency capped at 2 (`Indexer.swift:605`) — could widen
  for cold libraries on SSD.
- `recluster`'s `WHERE intent IS NOT NULL` scan (`CollectionsEngine.swift:107`)
  — negligible.

### Already optimized — do NOT "fix" these
- Grid virtualization (`MasonryGeometry.compute` O(n) pack, run only on
  set/column/width changes, never scroll; viewport-window materialization).
- `visibleFiles` memoized via `didSet` invalidation; `gridSignature` avoids
  full maps; `tileFrames` deliberately not `@Published`.
- ThumbnailCache: two-tier mem/disk, ordered concurrency gate with
  cancellation, ImageIO downsampling + decode budget, off-main decode, LRU cap.
- Incremental hashing (size+mtime local fast path, content-hash for iCloud,
  streaming 1MB SHA-256).
- DB indices on hot columns (paths, content_hash UNIQUE, collection_members,
  tags UNIQUE); FTS/tag-chip queries chunked (IN batches 800/500).
- Search field is local `@State` + 250ms debounce; FolderStat debounce has a
  maxWait cap.

---

## Part 2 — Feature gaps (verified absent, ordered by generalist-persona impact)

1. **File rename** — ✅ **APPROVED (2026-07-03) — do it.** Folders rename
   (`FolderOps.rename` incl. root parent-grant flow), files don't. Most
   conspicuous hole for the Downloads/Documents persona; the hard part (carrying
   the file's tags + collection memberships + DB identity) is already solved.
   Note: rename = a known relocation → must go through the same migration seam
   class as `AppState.moveFiles`/`FileMoveMigration` (repoint path row, carry
   tags/memberships), NOT a bare `FileManager.moveItem`.
   - **UI decision (owner, 2026-07-03): reuse the collection-rename modal
     (`NameCollectionAlert` — the `.alert` + text field + commit-on-Rename, with
     the local-`@State` draft pattern) for a consistent look.** Reuse the modal's
     UI, NOT its behavior: a collection rename just changes a DB label, whereas a
     file rename additionally (a) performs the real on-disk rename and (b) handles
     a name-collision with an existing file, then routes the relocation through
     `FileMoveMigration`/`moveFiles` so tags + memberships + identity carry.
   - **Scope (owner, 2026-07-03): base name ONLY — the extension is LOCKED, not
     editable.** Keeps it simple and sidesteps the `AssetKind` reclassification
     path entirely (no `.jpg`→`.png`). The editable field is the name minus its
     extension; the extension (last dot-suffix) is preserved and re-appended on
     commit — so the ONLY remaining edge case is name-collision. (Spec detail:
     multi-dot names like `archive.tar.gz` — treat only the last suffix as the
     extension.) Localize new strings (French); give the mouse action a parallel
     `.accessibilityAction`.
2. **Grid keyboard nav + spacebar open** — ✅ **APPROVED (2026-07-03) — do it.**
   No arrow-key cell navigation, no spacebar open in the grid today.
   **Approved design (owner):**
   - **Plain ↑ ↓ ← → move the HIGHLIGHTED photo (selection), grid auto-scrolls
     to follow** — Apple Photos / Finder icon-view convention (Option B). This
     REPLACES today's behavior where plain ↑/↓ scroll the view (verified: the
     grid deliberately forwards plain arrows to the `NSScrollView` to line-scroll
     — see `PageScrollCatcher.keyDown` forwarding at `:106–117`).
   - **Fn+↑ / Fn+↓ (Page Up/Down) = fast page scroll — REUSE the existing
     `PageScrollCatcher`, unchanged** (already handles the Page keys + Fn+arrow,
     `PageScrollCatcher.swift:104–105`). Optional: Fn+← / Fn+→ (Home/End) jump to
     top/bottom.
   - **Spacebar opens the highlighted photo big** — same path as double-click
     (sets `appState.selectedFile` → hero viewer). **NO Quick Look.** This
     sidesteps the video/QuickLook safety landmine ENTIRELY: the hero viewer
     already routes video/audio through the restricted `AVURLAsset.noNetwork`
     player, so videos "just work" and no file ever reaches `QLPreviewView`.
   - **Build notes:** needs a "current/highlighted tile" concept for keyboard nav
     (distinct from the multi-select `Set`); grid must scroll to keep it visible.
     **Hardest part — up/down in a MASONRY (uneven-height) grid:** "the tile
     directly above/below" isn't well-defined; needs a rule (e.g. nearest tile by
     horizontal center in the adjacent row band). Left/right wrap across rows.
     Parallel `.accessibilityAction` for the space-open + arrow moves; localize
     any new strings (French).
3. **List/details view** — ❌ **DROPPED (2026-07-03) — owner: no.** Weakest fit
   for the photo/asset-focused persona and the most work (a whole new view mode
   wired into all existing selection/action/keyboard machinery). Not doing it.
   (Was: no `Table`/columns view; masonry + 11 ratio grids only.)
4. **Copy/paste of files** — ❌ **DROPPED (2026-07-03) — owner: out of scope.**
   Copy/paste INTO folders is file MANAGEMENT (Finder's job), not organizing.
   Muse organizes via collections/tags; a user who needs filesystem ops uses
   "reveal original file" and does it in Finder. Not this app's role. See
   [[muse-scope-organize-not-file-manager]]. (Was: drag is move-only; no ⌘C/⌘V.)
5. **Slideshow / fullscreen compare** — ❌ **DROPPED for now (2026-07-04); one
   idea PARKED.**
   - **Compare: dropped.** Muse shows PREVIEWS, not high-res originals, so a
     side-by-side compare tool has no real purpose here (owner).
   - **Automated slideshow: dropped.** Owner dislikes anything auto-advancing
     ("lame" / "I don't like anything automated").
   - **PARKED idea (owner's tweak — noted, NOT building now):** a stripped-down
     FULLSCREEN immersive mode for a collection — just the image on its
     background (no info cards / metadata), navigated MANUALLY by arrow keys /
     swipe. Like the existing zoom/hero viewer but bare (image + backdrop only).
     Open question owner raised: how you'd enter/exit it. Owner's own read:
     probably NOT needed — the existing zoom feature already covers most of it,
     and previews (not high-res) make a dedicated immersive viewer less
     compelling ("doing it just to do it"). Keep as a future note.
6. **"Pro" bucket — triaged (2026-07-04):**
   - **Star ratings → ✅ APPROVED — "rating = premade tag + on-tile badge"
     (owner design, finalized 2026-07-04).**
     - **Storage/filter:** a rating IS a special manual tag (glyph label
       ★–★★★★★). Filters for FREE (click the ★★★★★ chip → all 5-star photos);
       safe from the auto-tagger (manual-beats-vision, per `(file_id,parent_dir)`);
       SORTS to the FRONT of the tag list/chip row.
     - **On-tile badge:** TOP-RIGHT corner, BLACK stars on a translucent WHITE
       backing (NO yellow — simple/clean, high-contrast, colorblind-safe). Shown
       ONLY when the photo is rated (unrated tiles stay clean — no clutter).
       DISPLAY-ONLY, NOT clickable (owner removed tap-to-remove: a badge click
       conflicts with tile select/open). Screen-reader labeled "N-star rating".
     - **Set / change / remove:** right-click context menu, 5 star options, a
       CHECKMARK on the current rating — pick another to change, pick the checked
       one to remove (NO "Remove" verb). MUTUALLY EXCLUSIVE (one rating per
       photo). Works on MULTI-SELECT (batch-rate the whole selection via the
       existing selection-actions path). ALSO a MENU-BAR command over the current
       selection so rating isn't mouse/right-click-only (accessibility; mirrors
       "New Collection from Selection…"). Parallel `.accessibilityAction`.
     - **Hero viewer (open/zoom):** NO star over the image (keep the image clean);
       the rating shows in the RIGHT panel, under Tags.
     - **Spec detail:** badge shows filled-only (★★★) vs out-of-five (★★★☆☆) —
       lean filled-only for a compact corner; decide at spec.
     - Rides the existing tag system; the ONE genuinely new visual is the small
       tile badge → low-to-moderate effort.
   - **Color labels → ❌ DROPPED.** Stars-as-tags cover it and don't fail
     colorblind users (owner).
   - **Video hover-scrub → ❌ SKIP (owner's "only if easy" rule).** Grounded: the
     SAFE frame-grab exists (`ThumbnailCache.videoFrame`, `.noNetwork` +
     `AVAssetImageGenerator.image(at:)`), and tiles have hover — but only a bool
     (`.onHover`), not position; smooth scrub needs continuous-hover position +
     throttling + in-flight cancellation + latency mgmt. MODERATE not easy, for a
     low-payoff case (few videos). Skipped.
   - **Batch rename, archive browsing, print → ❌ DROPPED** (file-management /
     already covered by collection PDF export / out of persona).
   - **EXIF write → ❌ SETTLED NO** (investigated + rejected 2026-06-27;
     [[muse-xmp-metadata-export-rejected]]).

Loose end: `Views/ImageDetailPanel.swift` still carries a "Phase 0
placeholder" header — the only explicitly unfinished component in the repo
(no TODO/FIXME markers anywhere else).

Feature-side blanket rules: every new user-facing string must be localized
(French ships; see CLAUDE.md localization rules); every mouse-only interaction
needs a parallel `.accessibilityAction`; any new input that narrows
`visibleFiles` must prune the selection; new selection actions must decide
explicitly whether folders are included (default: exclude).

---

## Part 3 — Cross-cutting constraints (read before ANY perf edit)

CLAUDE.md "Durable constraints & gotchas" is the authoritative list. The ones
most likely to be violated by performance work specifically:

- Grid must stay virtualized — no custom Layout / non-lazy container over the
  full file set.
- `setActiveTags` resolves the whole tag filter SYNCHRONOUSLY by design (the
  async version caused a visible jag) — don't "optimize" it back to async.
- The async `resort()` publish must stay behind all four tokens AND publish
  the intersection with the live grid.
- `AnalyzePipeline` pass claim (`acquirePass()`): every entry point that
  starts a pass must hold the claim; `analyze(folder:)`/`analyze(file:)` must
  not consult the flag themselves (deadlock).
- iCloud: content-hash change detection stays; dataless files are never
  read for classification/hash; no live SQLite in iCloud.
- Path-prefix containment checks need the trailing `+ "/"` rule.
- Never drive per-keystroke or perpetual-animation state through the AppState
  monolith / global `withAnimation(.repeatForever)`.
- Verification: `xcodebuild -scheme Muse test` green is necessary but NOT
  sufficient — verify behavior in the running app (repo rule).
