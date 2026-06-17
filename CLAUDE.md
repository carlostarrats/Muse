# Muse — Claude project notes

This file is loaded into Claude's context when working in this repo.
It documents the project's identity, current state, and conventions
so a fresh Claude session can pick up productively.

## Project identity

Muse is a **filesystem-native universal file viewer + AI-organized
asset library** for macOS, in the spirit of Adobe Bridge but
local-first, Apple-Intelligence-native, and free forever.

- Distribution: **Direct** — a Developer ID–signed, notarized build that
  self-updates via **Sparkle**, hosted on GitHub Releases (DMG with a
  drag-to-Applications background). **Not the Mac App Store**: Sparkle
  self-update is incompatible with MAS, and shipping directly lets updates
  go out without an App Store submission. Still **sandboxed**. (Pivoted from
  MAS on 2026-06-15 — see that session log. If a MAS build is ever wanted,
  it must be a separate target/config with Sparkle compiled out.) Release
  workflow: `docs/RELEASING.md`.
- Pricing: **Free**, no IAPs, no subscriptions, no ads
- Network policy: **Update-only**. No analytics, no telemetry, no data
  collection, no remote content fetches. The **only** network access is
  Sparkle: fetching its signed appcast feed + downloading the update, gated
  by `com.apple.security.network.client` (added 2026-06-15 for Sparkle, the
  sole network code path). Every download is EdDSA-verified against the
  embedded `SUPublicEDKey`. `SUEnableAutomaticChecks = true` so Sparkle checks
  quietly in the background with no UI unless an update exists (the first-run
  consent prompt was removed 2026-06-15 — it was a confusing first launch and
  its modal stole focus from the main window).
  iCloud Drive *document* sync (the optional single "Muse" iCloud folder) is
  mediated by the OS sync daemon and adds only the iCloud Documents
  entitlement. The developer still receives **no data**, so the "Data Not
  Collected" privacy label is unchanged.
- Data collection: **None**. Privacy nutrition label = "Data Not Collected".
- Min macOS: **14.6** (Vision/PDFKit/AVKit/FSEvents/FTS5 all work).
  Foundation Models is used only to name auto-generated collections,
  capability-gated to Apple Intelligence Macs (macOS 26+); the in-app
  chat panel was retired (see the 2026-06-12 session log).
- Primary user persona: **generalist** — managing a Downloads folder,
  Documents, miscellaneous archives. Defaults bend to fast Quick Look
  + Open With; AI features available but not the front door.

## Plan documents

The full design lives in:

- `docs/superpowers/plans/file-viewer-rewrite.md` — the binding plan.
- `docs/superpowers/specs/2026-06-10-post-rewrite-polish-design.md` — the
  polish-pass spec (all four phases shipped: AI brain ✅, hero viewer ✅,
  spatial views ✅, delights ✅).
  Five rounds of review revisions baked in. All open product questions
  resolved. Implementation status reflected in the phase log below.

Read this before making any non-trivial change. The identity
reconciliation matrix in §4 and the FileNode lifecycle table in §3.1
are the load-bearing reference artifacts.

## Implementation status

| Phase | Status | Branch where it landed |
|---|---|---|
| 0 — strip import-based code paths | ✅ shipped | `feat/file-viewer-rewrite` |
| 0.5 — v0.1 filesystem shell | ✅ shipped | `feat/file-viewer-rewrite` |
| 1 — indexing + read-only viewers + starring | ✅ shipped | `feat/file-viewer-rewrite` |
| 2 — universal viewer fill-out | ✅ shipped | `feat/file-viewer-rewrite` |
| 3 — Vision pipeline + tag panel + smart sort | ✅ shipped | `feat/file-viewer-rewrite` |
| 4 — duplicate finder + delete-to-trash | ✅ shipped | `feat/file-viewer-rewrite` |
| 5 — FTS5 search + scope toggle | ✅ shipped | `feat/file-viewer-rewrite` |
| 6 — App Intents (Shortcuts/Siri/Spotlight) | ✅ shipped | `feat/file-viewer-rewrite` |
| 7 — chat panel (Foundation Models, gated) | ✅ shipped | `feat/file-viewer-rewrite` |
| 8 — Globe rework + water shader on grid tiles | ✅ shipped | `feat/file-viewer-rewrite` |
| Polish 1 — AI brain (protocols, semantic search, living collections) | ✅ shipped | `feat/ai-brain` (merged) |
| Polish 2 — hero viewer (adaptive wash, info cards, zoom/pan, delete+undo) | ✅ shipped | `feat/hero-viewer` (merged) |
| Polish 3 — spatial views (cloud + graph, globe retired) | ✅ shipped | `feat/spatial-views` (merged) |
| Polish 4 — delights (burn-up delete, background moods) | ✅ shipped | `feat/delights` (merged) |
| Polish 5 — cloud rework (3D orbit ball) + galaxy view (similarity cloud, replaces graph) | ✅ shipped | `main` |
| Polish 6 — screenshot intent collections + Galaxy taste-map (color by intent) | ✅ shipped | `main` |
| Polish 7 — grid virtualization (perf) + thumbnail prewarm; cloud/galaxy views removed | ✅ shipped | `main` |
| Polish 8 — iCloud sync folder (portable `.muse` sidecars, no re-Vision) + macOS share (Share button + "Send to Muse" extension) | ✅ shipped | `feat/icloud-sync-share` |
| Polish 9 — Page Up/Down grid scrolling (Fn+Arrow on Mac) | ✅ built, unmerged | `feat/page-scroll` |
| Polish 10 — share a collection as a paginated 11×14 PDF (Save to… / Share menu) | ✅ built, unmerged | `feat/collection-pdf-share` |
| Polish 11 — grid multi-select + actions (collection/tag/share/move), drag-to-move, Reveal in Finder, native search field | ✅ built, unmerged | `feat/multi-select` |

> **2026-06-16 session — three feature branches off `main`, not yet merged.**
> Each has its own spec + plan in `docs/superpowers/`. Merge order is
> independent; reconcile this file's session log + architecture map on merge.

`feat/file-viewer-rewrite` was merged to `main` after Phase 8
finished — see the merge commit. The branch was kept around as an
audit trail of the per-phase progression.

### Post-polish session — 2026-06-12 (on `main`)

A long live-review pass. Landed:

- **Hero viewer polish** — late-Colors-card jump fixed, toolbar
  returns animated with the close flight, same-frame tile handoff (no
  landing blink), square corners on image tiles + stage, zoom backing
  card behind the right rail.
- **Collections, redesigned** — Cosmos-style 312pt cards with a 3×2
  cover mosaic, name + count; the COLLECTIONS header and ⌘K overlay are
  gone (scrollable row replaced both). Opening a collection shows ALL
  members library-wide (not the folder intersection) with an editable
  header (rename/delete + warning). Counts are alive-aware: deleting
  images or removing folders shrinks/hides collections automatically.
- **Tag chips row** above the grid — folder-scoped top tags; tap to
  filter, hover for count (no-reflow neighbor condense). Full tag
  management (add from a tile, rename/delete a label globally) plus
  menu-bar Tags/Collections commands for accessibility.
- **Automatic intelligence** — the ✨ Analyze button is gone. After
  indexing, the Vision pipeline runs automatically on new/changed
  images only (gated by `files.analyzed_hash` vs `content_hash`).
  Indexer has a size+mtime fast path so folder revisits are instant.
  180-day retention housekeeping (`Housekeeping.swift`) purges index
  data for files unreachable from any sidebar folder.
- **Background moods, reworked** — Light / Dark / Auto (day↔night by
  clock) / Custom (HSB sliders), one popover (`MoodPickerView`).
  AutoTint (content-dominant blend) retired.
- **Shell cleanup** — window title + breadcrumb removed; sort + show-
  subfolders moved left of search; Find Duplicates → File menu;
  Show-Details panel removed (viewer info column covers it); ⓘ About
  sheet (`InfoSheet`) explains the behind-the-scenes behavior. Bottom-
  center glass status pills (Analyzing → Indexing → Loading images),
  bottom-right column-count slider, off-main throttled thumbnails with
  top-to-bottom ordered loading, video thumbnails from a ~1s frame,
  BGRA→RGB palette fix.
- **Not shipped** — a top-edge "gradual blur" effect was attempted at
  length and fully reverted; the only artifact kept is
  `docs/superpowers/assets/gradual-blur-prototype.html` (an approved
  visual reference for any future attempt). Per-element SwiftUI
  `.layerEffect`/`.visualEffect` is the wrong tool for a fixed-viewport
  overlay effect — it breaks container views and only touches elements
  currently in the band.

### Screenshot intent session — 2026-06-13 (on `main`)

Shipped two Pool-inspired, on-device features (spec:
`docs/superpowers/specs/2026-06-13-screenshot-aware-features-design.md`,
plan: `docs/superpowers/plans/2026-06-13-screenshot-intent-collections.md`):

- **Screenshot intent collections** — screenshots (only) are classified
  by an FM-gated on-device classifier (`IntentClassifier`: reads OCR +
  vision labels, 10 fixed buckets — recipe/shopping/places/receipt/quote/
  article/conversation/event/design/code, "prefer none" bias) into a new
  `files.intent` column (migration `v5_intent`). `CollectionsEngine` is
  now two-track: typed screenshots form stable `intent:<key>` collections
  (≥3 alive members, fixed names, rename-preserving) AND are EXCLUDED from
  the emergent clustering. Non-AI Macs leave intent nil (no heuristic),
  mirroring the namer gating. A one-time launch backfill (`IntentBackfill`)
  classifies pre-existing screenshots from stored OCR (no re-Vision). No
  new UI — ordinary collection cards.
- **Galaxy "taste map" trial** — screenshot nodes get a colored backing
  plane by bucket; non-screenshots stay neutral. Easy to remove if it
  doesn't earn its place.
- **Dropped (documented in the spec):** a screenshot→source-link feature
  (#5) — verified screenshots carry no source URL in pixels OR metadata;
  only downloaded images do (`kMDItemWhereFroms`), so recovering a
  screenshot's origin needs networked reverse-image search (ruled out).
  Also burst/obsession metrics (data-selling outputs, no user value).
- **Test-target repair** — `MuseTests` had not compiled since the
  graph→Galaxy / cloud / AutoTint / Mood refactors (orphaned test files
  referencing removed symbols). Removed AutoTint/GraphLayout/GraphModel/
  CloudLayout/Mood tests; fixed CollectionStore/Membership tests (they
  inserted files but no live `paths`, so the alive-aware `fetchAll`
  returned empty and crashed on `all[0]`). Suite green again (85 tests).
- **Note (FIXED 2026-06-13):** the "Indexing N of M" pill used to count
  every enumerated file in `IndexProgress.begin(urls.count)` BEFORE the
  size+mtime fast-path check, so it climbed 0→N on every launch even though
  already-known files skip hashing. `indexBatch` now runs a discovery pass
  first (`Indexer.isUnchanged`) and only counts files that genuinely need
  (re)hashing — a fully indexed folder does zero work and shows no pill.

### Performance + view-cleanup session — 2026-06-13 (on `main`)

A 1700-image inspo folder was unusably slow (jagged scroll, multi-second
lag opening an image). Fixed and trimmed:

- **Grid virtualized** — the old `MasonryLayout: Layout` over a plain
  `ForEach` was the root cause: a custom SwiftUI `Layout` materializes
  *every* subview (no windowing) and re-measured all 1700 on every pass;
  selecting a file republished `AppState` → 1700 tiles invalidated +
  synchronous O(n) relayout right as the hero open should run. Replaced
  with precomputed packing (`MasonryGeometry` from `AspectRatioCache`,
  which bulk-reads stored `width/height` + ImageIO header fallback) and a
  manual viewport window (only visible tiles + 1-screen overscan are
  live). Jigsaw look preserved exactly. `MasonryLayout.swift` deleted.
  See memory `muse-grid-must-stay-virtualized` — do NOT reintroduce a
  custom Layout / non-lazy container over the full file set.
- **Thumbnail prewarm** — indexing/analysis build metadata, not
  thumbnails, so the first scroll to the bottom generated them on the fly
  (the progress pill). `ThumbnailCache.prewarmToDisk` now warms the whole
  folder to the on-disk cache in the background after indexing; the pill
  only shows for genuinely cold generation (disk hits are silent). Disk
  cache persists across launches → instant scroll thereafter.
- **Cloud + Galaxy views removed** — judged not useable in their current
  iterations. Deleted `CloudView/CloudLayout/CloudMath/CloudPose/
  GalaxyView/GalaxyModel/SimilarityLayout/SceneProjection` and
  `IntentBucket.galaxyHex`; dropped `AppState.ViewMode`, `viewMode`,
  `graphFocusedCollectionID`, and the toolbar view picker. Grid is the
  only view (no button). `SeededRandom` kept (grid burn + hero). Intent
  collections (the typed-screenshot feature) are untouched — only the
  Galaxy *visualization* of them is gone.
- **Responsive folder selection** — `select(folder:)` blocked the main
  thread enumerating + sorting the folder synchronously (thousands of disk
  stats + a DB-backed sort), so clicking a big folder froze until it
  finished. Now selection sets the folder + a loading flag instantly and
  `reloadCurrentFiles` does enumerate/merge/sort **off-main** (with a token
  so a newer pick wins), publishing on completion; the grid shows a pulsing
  **skeleton** (`isLoadingFolder`) meanwhile. `SmartSorter` made nonisolated
  for off-main sorting. Indexing/prewarm/analysis kick off after files land.
- **Honest progress pills** — `indexBatch` runs a discovery pass
  (`isUnchanged`) and only counts files that truly need (re)hashing, so a
  fully-indexed folder shows no indexing pill. Analyze pill shows a
  fixed-width count ("Analyzing N of 835"), not a jittering filename; pills
  hug their content. `analyze(folder:)` dedupes by file id (path dupes →
  one analysis).
- **iCloud size/mtime oscillation (the big one)** — `~/Library/Mobile
  Documents/.../Saved Inspo` (iCloud Drive) re-indexed ~920 files on EVERY
  visit, freezing the UI. Root cause: iCloud returns **different size/mtime
  on successive reads of the same downloaded file** (they flip between two
  values), so the size+mtime fast path could never converge — and the
  "unchanged" reconcile path didn't even write metadata back. Fix:
  `Indexer.isUnchanged` now takes `isUbiquitous` (true when the URL reports
  a `ubiquitousItemDownloadingStatus`); for iCloud items it **trusts the
  existing `content_hash`** and skips re-hashing entirely (local files keep
  the exact size+mtime check). **Do NOT reintroduce a size/mtime comparison
  for iCloud items** — it will reindex the whole folder every visit. Genuine
  iCloud edits are expected via sync + the folder watcher, not metadata
  polling.
- **Possible follow-up (not done):** disk-hit thumbnails load via
  `NSImage(contentsOf:)`, which decodes lazily on the main thread at first
  draw — a candidate if any residual scroll hitch remains. Force-decode
  off-main (ImageIO, like `HeroStage.loadFullRes`) if so.

### iCloud sync folder + macOS share session — 2026-06-13 (on `feat/icloud-sync-share`)

Shipped iCloud-backed sync and two share surfaces (spec:
`docs/superpowers/specs/2026-06-13-icloud-sync-and-macos-share-design.md`,
plan: `docs/superpowers/plans/2026-06-13-icloud-sync-and-macos-share.md`):

- **Two-zone model** — local zone (today's user-selected security-scoped
  folders, unchanged) + a new optional iCloud zone: ONE app-managed "Muse"
  folder in the app's iCloud Drive ubiquity container, auto-discovered on
  every signed-in device (not re-picked per device). Users may create their
  own subfolders inside it. Local-only, iCloud-only, and mixed users are
  all first-class.
- **Complete portable sidecar** — files in the iCloud folder carry a hidden
  `.muse/<content_hash>.json` per-asset sidecar (tags, intent, caption,
  dominant color, palette, dimensions, feature print, analyzed_hash) that
  rides the same OS sync. On folder load `SidecarHydrator` imports current
  sidecars into the local DB and sets `analyzed_hash`, so a fresh/iCloud-only
  device reconstructs the experience WITHOUT re-running Vision. Collections
  and thumbnails re-derive locally; OCR text is intentionally NOT carried
  (large; FTS gets basename+caption on hydrate).
- **iCloud Drive, not CloudKit** — document sync is OS-daemon-mediated, so
  the app makes zero network calls and adds only the iCloud Documents
  entitlement (no `network.client`); "Data Not Collected" holds. CloudKit
  was explicitly rejected (would add a network surface). No live SQLite file
  is ever placed in iCloud (corruption trap) — the sidecar is JSON snapshots
  written with NSFileCoordinator.
- **Conflict handling** — per-asset sidecars keyed by content hash isolate
  conflicts; merge is last-writer-wins by an `updated_at` metadata timestamp,
  with manual tags always beating vision tags (preserves invariant Q32).
- **Share surfaces** — in-app Share button on the hero viewer
  (`NSSharingServicePicker`: AirDrop/Mail/Messages/Save to Files) for sending
  an image OUT; and a "Send to Muse" share extension (right-click → Share in
  Finder) for bringing a file IN to the single iCloud folder, picked up by
  the existing FolderWatcher.
- **Xcode setup (done)** — iCloud Documents + App Groups capabilities + signing
  (team `TV4QZT7A7X`, container `iCloud.com.tarrats.Muse`, group
  `group.com.tarrats.Muse`) added to both the Muse target and a new
  `MuseShareExtension` macOS Share Extension target (shows as "Muse" in the
  Share menu). The Muse folder is published to Finder's iCloud Drive via
  `NSUbiquitousContainers` in `Muse/Info.plist` (at SRCROOT, outside the
  synchronized group; `INFOPLIST_FILE` + `GENERATE_INFOPLIST_FILE`), and
  `CFBundleVersion` was bumped to 2 so iCloud re-read it. The analyze→sidecar
  round-trip was verified on a real file (a `.muse/<hash>.json` was written).
  See memory `muse-icloud-folder-gotchas` for the empty-folder / version-bump /
  TCC pitfalls.
- **Pre-req fix** — removed orphaned `SimilarityLayoutTests`/`CloudMathTests`
  (referenced source deleted in the perf session) that were breaking the
  `MuseTests` target.

### Collections page + water removal + nav polish — 2026-06-13 (on `main`)

A live UI pass. Landed:

- **Water effect removed** — the fun-only water-ripple distortion is gone:
  `Fluid/FluidSim.swift` + `Fluid/FluidDistortion.metal` deleted, the toolbar
  water-droplet toggle and all `fluidEnabled`/`fluidSim`/`fluidDispImage`
  AppState plumbing stripped, GridView's `fluidDistort` layerEffect + mouse
  tracking removed. The burn-up DELETE effect (`BurnUp.metal` /
  `BurnUpModifier.swift`) is untouched — it never depended on the water shader.
- **Collections get their own page** (`CollectionsPage.swift`) — a new toolbar
  icon (`square.stack.3d.up`, left of the mood button) opens a dedicated page:
  a "Collections" header (back arrow, NO edit/trash, 42pt title, same 48+20pt
  gap-below as the in-collection view) over a 4-up card grid that resizes to
  fit the window width, wraps to multiple rows, scrolls vertically, ordered
  alphabetically. The old inline horizontal collections strip in the grid was
  removed — `CollectionsRow` now renders only the in-collection header.
  `CollectionCard`/`CollectionMosaic` take a `coverSize` so cards are
  resizable. New `AppState.showingCollections` + `toggleCollectionsPage()`;
  tapping a card drills in (page stays "open" so the in-collection back arrow
  returns to the page). Sort menu is disabled on the page; tags hidden there.
- **Tags work inside a collection (bug fix)** — selecting a tag then opening a
  collection used to hide BOTH the collection header (gated on
  `activeTagLabel == nil`) AND the tag chips (gated on `activeCollectionID ==
  nil`). Now: the header shows whenever a collection is active, the chips stay
  pinned inside a collection, and the chips re-scope to the collection's
  members via `AppState.tagSourceFiles` (= `activeCollectionFiles ?? currentFiles`,
  UNFILTERED so selecting a tag doesn't collapse the chip list). Tags now filter
  within a collection (intersection); "All" clears.
- **Smoother transitions** — the page⇄grid swap is a ZStack crossfade (was a
  VStack that collapsed/regrew top-down), driven by `.animation(value:)` on the
  active experience. Grid tiles and collection covers fade in over their
  placeholder as thumbnails decode (was a hard snap).
- **Nav consistency** — the clear-collection ✕ toolbar button removed entirely
  (back arrows cover it). The mood/paint button is a native `Toggle` with
  `.toggleStyle(.button)` so it shows the standard macOS selected fill (solid
  accent, white icon) while its popover is open — no custom chrome. Tag-chip
  row uses a constant 24pt bottom gap (was 14 vs 24) so the grid doesn't jump
  vertically between a selected tag and "All".
- **Not a bug** — double-clicking the Info button "zooms" the window: that's the
  standard macOS "double-click the title bar to zoom" (the toolbar is in the
  title bar), governed by System Settings, not app code.

### Bulk tag commands + Organizing pill — 2026-06-13 (on `feat/next-2`)

Two folder-scoped Tags menu commands and a progress pill (spec:
`docs/superpowers/specs/2026-06-13-bulk-tag-commands-design.md`, plan:
`docs/superpowers/plans/2026-06-13-bulk-tag-commands.md`):

- **Delete All Tags… / Regenerate Tags…** — new items in the menu-bar Tags
  menu, both scoped to the CURRENT folder's files (`AppState.currentFiles`),
  not library-wide. Delete (`TagStore.deleteAllTags(forURLs:)`) removes every
  tag — manual AND vision — for the folder's files, but **deliberately leaves
  `analyzed_hash` untouched** so the automatic pipeline never resurrects them;
  they only return via an explicit Regenerate. No FTS cleanup needed (tags
  aren't in `files_fts`; tag search is a separate label lookup). Regenerate
  (`AnalyzePipeline.regenerateTagless(in:)`) re-runs Vision only on folder
  files with **zero tags** — a "no-tags" gate (NOT an `analyzed_hash` reset),
  which makes it both the recovery path (after a wipe all files qualify) and
  incremental (a fully-tagged folder is a no-op). Tags are content-identity
  keyed (by `file_id`), so this matches the app's existing tag model: a
  byte-identical duplicate in another folder shares the same tag rows.
- **"Organizing…" pill** — `ContentView` now observes
  `CollectionsEngine.isClustering` and shows the same glass capsule during the
  post-analyze recluster, closing the previously-invisible gap between the
  "Analyzing N of M" pill vanishing and results appearing (Regenerate made it
  noticeable). Purely additive view code.
- **Two QA-found bugs fixed** — (1) the menu items were enabled whenever the
  folder had files, but their confirmation alerts live on `TagChipsRow`, which
  is unmounted during search and on the Collections card page → firing there
  was a silent no-op that popped a ghost destructive alert later. Now gated on
  `AppState.bulkTagCommandsAvailable` (matches exactly where TagChipsRow is
  mounted). (2) An open hero viewer showed stale tag pills after a menu
  Delete/Regenerate because `details` reloads via `.task(id: currentURL)`;
  added an `.onChange(of: tagsVersion)` reload.
- **Known, accepted limitation (not fixed):** `CollectionsEngine.recluster()`'s
  `guard !isClustering` can drop a regenerate's trailing recluster if a prior
  recluster is in flight, so collections can lag by one analyze pass. It's
  pre-existing, self-healing on the next analyze, and a fix would change core
  clustering across every analyze path — left alone deliberately.

### Viewer zoom-out + Duplicates redesign + sidebar reorder — 2026-06-14 (on `feat/next-6`)

A live UI/UX pass. Landed:

- **Hero viewer zoom-out** — `ViewerGeometry.minZoom` 1.0 → 0.7 so the image
  can be pulled back a touch below Fit (bounded, not infinite). The zoom pill's
  − / + buttons grey out (and disable) at the min/max limit. "Fit" detection is
  now `abs(zoom - 1) <= 0.001` (was `zoom > 1.001`), so the Fit button + live %
  readout show when zoomed OUT too, not just in. Pan stays disabled below Fit
  (clampPan yields 0 for zoom < 1).
- **Duplicates modal redesign** (`DuplicatesView`) — dropped the per-group
  "Byte-exact · N files" header (the reason terminology confused; the thumbnails
  + KEEP badge carry the meaning). Rows now sit on ONE faint panel
  (`Color.primary.opacity(0.05)` — `controlBackgroundColor` is white in light
  mode and vanished) separated by hairline dividers, not per-group grey cards.
  KEEP badge centered over the image (thumbnail switched to `.fill` + `.clipped`
  so it no longer floats in a letterbox gap). Header matches InfoSheet (24pt
  title + shared hover-X `CloseXButton`, no divider beneath). Move-to-Trash now
  closes the modal (the group list is a stale snapshot that doesn't re-derive,
  so leaving it open looked like nothing happened).
- **Grid spacing** — masonry gutter 10 → 14pt (one `spacing` value drives rows
  and columns + the skeleton, so all widen equally).
- **Sidebar: drag-to-reorder top-level folders** — added a custom `DropDelegate`
  (`RootDropDelegate`) with an accent insertion line, before/after half-detection
  (top half of a row → above, bottom half → below; a constant bottom catch-zone
  handles "send to the end"). The reorder is committed by **Root identity**
  (`BookmarkStore.reorder(_:relativeTo:placeAfter:)`), NOT by visible index — a
  root whose bookmark doesn't resolve is hidden from the list but kept in the
  store, so an index-based move would shift the wrong folder. Order persists in
  the existing UserDefaults bookmark array.
- **Pin restricted to subfolders** — top-level roots are already visible at the
  top, so Pin is offered only on subfolders now (it's a shortcut for buried
  ones). The "Pinned" section header text was removed (the pin icon is
  self-explanatory). Right-clicking a root shows only Remove Folder.
- **iCloud "Muse" folder pinned on top** — it's the fixed home: always first,
  not reorderable (no bookmark → excluded from the reorderable set), with a 12pt
  gap separating it from the local folders.
- **Two observation bugs fixed** — (1) Pin/Unpin now refreshes the sidebar
  immediately: `stars` is a nested `ObservableObject`, so its changes are
  forwarded to `AppState.objectWillChange` (was only repainting on the next
  unrelated AppState change). (2) Reorder takes effect on the FIRST drop:
  `@Published` fires in `willSet`, so the `bookmarks.$roots` sink was rebuilding
  the sidebar from the OLD array; it now rebuilds from the value the publisher
  delivers (`rebuildRootNodes(roots:)`). `rebuildRootNodes` also reuses nodes by
  URL (consume-once, so duplicate-URL roots don't make duplicate `ForEach` ids)
  to preserve each tree's expansion across reorders.
- **QA pass** — two rounds of independent review; the identity-based reorder and
  consume-once node reuse above were the review-found fixes. Build green.

### Tagging overhaul: color naming + neutrals + label curation — 2026-06-15 (on `feat/next-7`)

Investigated "inaccurate image tags" (e.g. an all-blue vinyl image showing under
the **red** filter). Root-caused against the live DB; the decision (see memory
`muse-fix-code-not-my-data`) was to fix the **forward code** and validate by a
clean re-analysis — NOT to ship one-time data-migration passes to patch existing
corrupted DBs. Two root causes, plus a diagnosis of a third that needed no new code:

- **Identity collision — already fixed at the source, no new code.** On the dev
  DB ~51% of the library (915 distinct iCloud images) were welded onto a single
  phantom `files` row, so they all shared that record's tags/palette/caption —
  why a blue image showed under "red". Verified by hashing the files: different
  sizes + different SHA-256, none matching the phantom's stored hash. This was
  legacy damage from the OLD zero-byte-hash bug, which is **already guarded** in
  `HashService.sha256` (returns nil on a zero-byte read of a non-empty file). A
  fresh index therefore cannot re-weld — proven by wiping + re-indexing (below).
  (A migration to un-weld existing DBs was prototyped and then removed as a
  band-aid: the user's library is a disposable test fixture; real fix = the hash
  guard + re-analyze. The lingering caveat is unchanged: for iCloud files
  `Indexer.isUnchanged` trusts the stored hash and never re-hashes, so the
  size/mtime change-signal doesn't apply there — fine for a clean index, but it
  means a corrupted iCloud DB couldn't self-heal without a wipe.)
  This was a whole-system tagging pass, not a one-band patch. Three forward fixes:

- **Color naming (`NamedColor`) — robust across every hue + neutrals.** The bug
  class generalised well beyond red: (a) pale warm tones (skin/peach/salmon) were
  called "red"; (b) muted mauve/taupe was "red"; (c) **near-black charcoals
  (`#202226`, `#282429`) were called "blue"/"purple"** because a near-neutral has
  a hue mathematically but it's just channel noise. Fixes:
  - Achromatic gate *before* any hue read: `brightness < 0.16` ⇒ black; dark +
    weakly-saturated (`brightness < 0.30 && saturation < 0.35`) ⇒ black (charcoal,
    not a hue — genuinely dark *saturated* navy/maroon still keep their hue);
    `saturation < 0.12` ⇒ white/gray by brightness.
  - Red band: pale warm ⇒ pink; muted/not-bright warm
    (`brightness < 0.7 && saturation < 0.45`) ⇒ brown; saturated reds (maroon
    incl.) stay red.
- **Color dominance (`ColorTagger` + `PaletteExtractor.kmeansWeighted` /
  `weightedPalette`).** Tagging now uses each cluster's **share**: the dominant
  cluster is always named, others only if they cover ≥15% of the image, deduped +
  capped at 3. `VisionTagger` uses the weighted path; the stored `palette` keeps
  the full sorted list (backdrop/wash). Kills the "minor accent tags the whole
  image" failure mode at analysis time.
- **Classification labels (`ClassificationCuration`, wired into `VisionTagger`).**
  Apple Vision's raw taxonomy was surfaced verbatim — abstract terms (`material`,
  `structure`, `conveyance`, `container`, `carton`), sensitive demographic guesses
  (`adult` was on 242 files, `male`/`female`), and underscored compounds
  (`wood_processed`, `blue_sky`, `printed_page`, `footwear`). Curation: confidence
  floor (0.45) + top-5 cap, a drop-set for noise/sensitive labels, a remap for
  known-ugly → friendly (`wood_processed`→wood, `blue_sky`→sky, `footwear`→shoes,
  `printed_page`→document, `illustrations`→illustration…), and a generic
  underscore→space fallback. Deduped after remap.
- **Stale tags were a symptom, not a cause.** Files whose stored tags disagreed
  with their content were just frozen by the incremental `analyzed_hash` gate — a
  re-analysis regenerates them correctly, so no migration was needed.

Tests: added `ColorTaggerTests`, `ClassificationCurationTests`; extended
`NamedColorTests` (dark-neutral, light-neutral, dark-saturated cases) /
`PaletteExtractorTests`; fixed a stale `ViewerGeometryTests.testZoomClamp`
(2026-06-14 minZoom 1.0→0.7, unrelated pre-existing failure).

**Validated end-to-end** by wiping `muse.sqlite` and re-analyzing the real
~1.7k-image library from scratch: max 2 paths/file (no welding — the hash guard
holds on a clean index); all 1740 images analyzed; `black` rose to 569 as
charcoals left blue/purple; **0 of 3447 color tags lack a matching palette color**
(every band, checked with a NamedColor replica); **no banned/sensitive labels
present** (`adult` etc. gone); visual contact-sheet audit (montages per color band
+ per classification label) confirmed image↔tag agreement for people/document/
shoes/sky and the color bands.

### Self-update (Sparkle) + distribution pivot — 2026-06-15 (on `main`)

Added a **Check for Updates** flow and pivoted distribution away from the Mac
App Store. Decision was the user's, confirmed up front: direct distribution +
GitHub Releases hosting (the two App-Store/zero-network constraints below are
genuinely incompatible with Sparkle, so this was surfaced before any code).

- **Sparkle 2.x via SPM** (`https://github.com/sparkle-project/Sparkle`,
  resolved 2.9.3), wired into `project.pbxproj` by mirroring the existing GRDB
  SPM entries (the `Muse` group is a `fileSystemSynchronizedGroups` root, so
  new `.swift` files are auto-included — only the package refs needed manual
  pbxproj edits). `Updates/Updater.swift` holds an `SPUStandardUpdaterController`
  wrapper + `CheckForUpdatesView`; `MuseApp` owns it and adds the menu item via
  `CommandGroup(after: .appInfo)` (right under "About Muse").
- **Info.plist:** `SUFeedURL` →
  `https://github.com/carlostarrats/Muse/releases/latest/download/appcast.xml`,
  `SUPublicEDKey` = the EdDSA public key. `SUEnableAutomaticChecks = true` —
  Sparkle checks quietly in the background, no UI unless an update exists. (The
  first-run consent prompt was tried first but removed 2026-06-15: it was a
  confusing first launch AND its modal stole focus so the main window didn't
  appear until the user clicked the Dock icon.)
- **Entitlement:** added `com.apple.security.network.client` — the FIRST and
  ONLY network entitlement, solely for Sparkle's appcast fetch + download.
  Verified the built app embeds `Sparkle.framework` with its sandbox XPC
  services (`Downloader.xpc` / `Installer.xpc`) and that the codesigned
  entitlements include `network.client`. **This breaks the old literal
  "zero network calls" guarantee** — the docs now say "update-only network".
  The "Data Not Collected" label still holds (Sparkle sends no profile data;
  system-profile reporting is off).
- **EdDSA key:** a pre-existing Sparkle signing key in the login Keychain
  (shared with the user's other Sparkle app) was reused via `generate_keys`;
  the private key stays in the Keychain, never committed.
- **DMG:** release artifact is a DMG with a drag-to-Applications background
  (`dmg/dmg-background.jpg`); `scripts/make-dmg.sh` builds it. See
  `docs/RELEASING.md` for the full archive→notarize→sign→appcast→publish flow.
- **Docs:** rewrote the Distribution + Network-policy identity bullets here,
  the README Privacy section (+ a "Staying up to date" section), and added
  `docs/RELEASING.md`.
- **Shipped v1.0.0 live (2026-06-15).** The repo was made **public** and
  licensed **MIT** (`LICENSE`) — required because Sparkle fetches the appcast
  unauthenticated, and a private repo's `releases/latest/download/…` URLs 404
  for everyone (that was the "couldn't retrieve update information" error).
  README has a Lineform-style download badge → `releases/latest/download/
  Muse-<version>.dmg`; `release.sh --publish` auto-bumps that version.
- **Notarization gotchas baked into `release.sh`:** (1) **Hardened Runtime is
  required** — the app was MAS-configured (no hardened runtime), so the first
  notarization came back *Invalid*; `release.sh` archives with
  `ENABLE_HARDENED_RUNTIME=YES`. (2) `notarytool submit --wait` exits 0 even on
  an *Invalid* result, so the script now checks for `status: Accepted` and
  dumps the log on failure. (3) iCloud + App Groups need provisioning profiles
  even for Developer ID → `-allowProvisioningUpdates`. (4) stapling can lag
  Apple's ticket → `staple_retry`.
- **Sandboxed install fix (the big one for self-update):** a sandboxed app
  can't launch Sparkle's installer directly — the first real update downloaded
  + verified but died at "launching the installer." Fix: Info.plist
  `SUEnableInstallerLauncherService = true` + entitlements `mach-lookup`
  temporary-exception for `com.tarrats.Muse-spks`/`-spki`. Takes effect for the
  app DOING the update, so pre-fix builds can't self-update — the first fixed
  build must be installed manually once.
- **First-run UX:** `SUEnableAutomaticChecks = true` (silent background checks,
  no consent prompt — the prompt confused users AND its modal stole focus so
  the window didn't appear until a Dock click).
- **VERIFIED end-to-end (2026-06-15):** shipped v1.0.0→v1.0.3; self-update
  proven (installed 1.0.2 → Check for Updates → downloaded, EdDSA-verified,
  installed, relaunched on 1.0.3). Each release publishes a clean single-item
  appcast (`--maximum-deltas 0`, dir pruned to the current DMG — GitHub hosts
  assets per-tag so cross-tag deltas/old entries would 404). Full release flow:
  `docs/RELEASING.md`; one command: `scripts/release.sh <version> --publish`.

### Three feature branches — 2026-06-16 (off `main`, built + reviewed, unmerged)

A long session that shipped three independent features, each as its own
branch with a spec + plan under `docs/superpowers/`. All build green; the
multi-select work went through two adversarial review rounds.

- **Page Up/Down grid scrolling** (`feat/page-scroll`). `Fn+Arrow` (the Mac
  "Page Up/Down" — most Mac keyboards have no dedicated keys) or real Page
  keys jump the grid one screenful, in the main/tag/in-collection grids and
  the Collections page. Pure `PageScroll.newOriginY` math (overlap + clamp,
  unit-tested) + `PageScrollCatcher`, an NSView that becomes first responder
  (KeyCaptureView pattern), resolves the backing `NSScrollView` via
  `enclosingScrollView`, animates the clip view, and `flashScrollers()`.
  Reclaims focus on a grid click; ignores keys while editing text or with a
  hero viewer open; forwards non-page keys down the responder chain.
  Spec/plan: `2026-06-16-collection-pdf-share` siblings.

- **Share a collection as a PDF** (`feat/collection-pdf-share`). A Share
  control in the in-collection header (left of the trash) opens a **menu**:
  **Save to…** (`NSSavePanel`, defaulted to Desktop — no new entitlement) and
  **Share** (unmodified `NSSharingServicePicker`). Both build a paginated
  **11×14in portrait** PDF of the collection's images — masonry pack, whole
  images (no crop), title + count at 24pt on page 1 only, column density =
  the user's `gridColumnCount`. `CollectionPDFLayout` (pure, paginated, no
  image split across pages, unit-tested) + `CollectionPDFExporter` (ImageIO
  downsample off-main → CGPDFContext, CoreText header — no AppKit off-main).

- **Grid multi-select + actions** (`feat/multi-select`). Single-click selects
  (instant, manual double-click detection — no SwiftUI count:1/2 delay),
  Cmd-click toggles, Shift-click ranges, double-click opens. Selection =
  `AppState.selectedFiles: Set<String>` of standardized paths (pure
  `GridSelection` math, unit-tested); accent wash + border inside the tile so
  it scales with the hover zoom; `.isSelected` VoiceOver trait + spoken count.
  Selection-aware right-click menu (`SelectionActionsMenu`): **Add to
  Collection** (`CollectionStore.addFile`), **Add Tag** (existing labels,
  preloaded into `AppState.allTagLabels` — a context-menu `.task` doesn't fire
  reliably), **Share**, **Move to Folder** (keyboard/VoiceOver-accessible
  parallel to drag). **Drag** a selection onto a sidebar folder to **move**
  (`FileMover` — roots already hold RW security scope, so no per-move scope;
  failures → alert). **Reveal in Finder** on sidebar folders. **Deselect** via
  empty-grid tap, the sidebar surface, and an `OutsideClickDeselect` mouse
  monitor (clicks outside the grid scroll view); also on folder/collection/
  tag/search switches and Edit ▸ **Deselect All** (⌘⇧A) / **Select All** (⌘A,
  which defers to a focused text field). The search bar was replaced with a
  native **`NSSearchField`** (system focus ring, clear button, accessibility;
  appearance follows the mood). Known limitation: the sidebar drop reads the
  grid selection, so dragging a *Finder* file onto a sidebar folder would move
  the grid selection rather than import the dropped file (rare; not fixed to
  avoid risking the verified in-app drag).

## Architecture map (current — see the 2026-06-12 session log for deltas)

```
Muse/Muse/
  MuseApp.swift                    entry point; ThumbnailCache LRU prune +
                                   180-day Housekeeping prune + IntentBackfill
                                   on launch; owns the Sparkle updater +
                                   "Check for Updates…" command (after .appInfo)
  Updates/
    Updater.swift                  Sparkle SPUStandardUpdaterController wrapper +
                                   CheckForUpdatesView (menu item, disables while
                                   a check is in flight). Direct-distribution
                                   self-update; see docs/RELEASING.md
  ContentView.swift                NavigationSplitView shell; floating tag
                                   chips; toolbar; menu-bar Tags/Collections
  Models/
    AppState.swift                 @MainActor singleton — roots, active folder,
                                   current files, selected file, sort mode,
                                   search, collection + tag filters, mood. Grid
                                   MULTI-selection (selectedFiles: Set<String> of
                                   paths + anchor): applyClick / clearSelection /
                                   selectAllVisible / effectiveSelectionURLs;
                                   reloadAfterMove; allTagLabels preload
                                   (feat/multi-select)
    AssetKind.swift                kind enum + extension/UTType detection
    FileNode.swift                 in-memory enumerated-file value type
    Root.swift                     security-scoped bookmark wrapper
    DeleteCoordinator.swift        delete state machine (trash + undo toast);
                                   drives a fade-out (internals still named
                                   "burn"; the Metal burn shader is gone)
    Mood.swift                     Light / Dark / Auto (day↔night) / Custom HSB
                                   (AutoTint retired)
  Filesystem/
    FileMover.swift                move(_:into:) via FileManager.moveItem; skips
                                   name collisions, returns failures; roots already
                                   hold RW security scope (feat/multi-select)
    BookmarkStore.swift            UserDefaults-backed root bookmarks; lifecycle
                                   start/stop access for sandbox
    FolderTree.swift               lazy hierarchical tree + FolderReader
    FolderWatcher.swift            FSEvents-backed live watcher
    StarStore.swift                SQLite-backed starred folders
    ThumbnailCache.swift           QLThumbnail + AVAssetImageGenerator (videos);
                                   off-main, ordered (top→bottom) load; 2-tier
                                   cache (NSCache 512MB cost + on-disk LRU 2GB)
    Sidecar.swift                  portable per-asset metadata value type
                                   (Codable); maps to/from FileRow+TagRow;
                                   deterministic conflict merge (manual-tag wins)
    SidecarStore.swift             read/write .muse/<hash>.json with
                                   NSFileCoordinator (no live SQLite in iCloud)
    ICloudZone.swift               discover the single app iCloud Drive folder
                                   (ubiquity container Documents) + membership test
    SidecarHydrator.swift          import current sidecars into local DB on folder
                                   load so a fresh/iCloud-only device skips re-Vision
  Database/
    Database.swift                 GRDB queue + migrations (v1…v5_intent)
    Records.swift                  FileRow (+analyzed_hash, +intent), PathRow, TagRow, etc.
    SearchService.swift            FTS5 + tag-label search (sidebar-folder scope)
    TagStore.swift                 manual/vision tag CRUD + global rename/delete
    Housekeeping.swift             launch prune: index data for files unreachable
                                   from any sidebar folder, unseen >180 days
  Indexing/
    HashService.swift              streaming SHA-256; nil on dataless iCloud reads
    Indexer.swift                  identity reconciliation matrix (§4); size+mtime
                                   fast path; skips not-downloaded iCloud items
  Intelligence/
    Vision/
      VisionServices.swift         classify/OCR/faces/feature print/dom color
                                   + CaptionBuilder (Vision-derived, NOT LLM)
    Sort/
      SmartSorter.swift            7 sort modes; Color + Shape pull FileRow data
    Dedup/
      DuplicateFinder.swift        byte-exact + visual + filename clusterers
                                   with smart-suggest only where signal is strong
    Core/
      PaletteExtractor.swift       k-means palette (RGBA-redraw; BGRA bug fixed)
      CollectionNaming.swift       Foundation Models namer (gated) → tag fallback
      IntentBucket.swift           10 screenshot-intent buckets: keys, display
                                   names, stable collection ids, raw→bucket, color
      IntentClassifier.swift       pure IntentInput helpers + FM-gated classifier
                                   (screenshot OCR+labels → bucket | none)
    Collections/
      CollectionsEngine.swift      two-track recluster: intent collections (typed
                                   screenshots) + emergent (everything else)
      IntentCollections.swift      pure: which intent buckets qualify (≥3 members)
    AnalyzePipeline.swift          AUTOMATIC after indexing — analyzes only stale
                                   analyzed_hash files; writes FileRow, tags, FTS5;
                                   classifies screenshot intent (gated)
    IntentBackfill.swift           one-time launch pass: classify pre-existing
                                   screenshots from stored OCR (no re-Vision)
  Agents/
    AppIntents/
      MuseAppIntents.swift         OpenFolder/FindDuplicates/AnalyzeFolder/
                                   SearchLibrary intents + AppShortcutsProvider
  Viewers/
    PDFViewerView.swift            PDFKit, view-only
    TextViewerView.swift           NSTextView wrapper, isCode/isRTF flags
    MarkdownViewerView.swift       AttributedString markdown
    SVGViewerView.swift            WKWebView, file:// only (no network)
    VideoPlayerView.swift          AVKit AVPlayerView
    AudioPlayerView.swift          AVKit + asset metadata
    ModelViewerView.swift          SCNScene from URL
    FontViewerView.swift           process-scope font registration
    ViewerChrome.swift             dimmed bg + close button + Esc dismiss
  Views/
    SidebarView.swift              multi-root OutlineGroup tree + starred section;
                                   file-URL drop on folder rows MOVES the grid
                                   selection there (FileMover) with a drop-target
                                   highlight; Reveal in Finder menu item
                                   (feat/multi-select)
    GridView.swift                 VIRTUALIZED masonry grid — precomputes tile
                                   frames (MasonryGeometry from AspectRatioCache)
                                   and renders only viewport tiles (+overscan);
                                   column-count slider; tiles fade in as thumbs
                                   land. The ONLY grid view (cloud/galaxy retired
                                   2026-06-13; water effect removed 2026-06-13).
                                   Click = select (instant; Cmd toggles, Shift
                                   ranges), double-click opens; accent wash+border
                                   inside the tile (scales w/ hover); .onDrag carries
                                   the file URL; selection-aware contextMenu
                                   (feat/multi-select)
    SelectionMenu.swift            SelectionActionsMenu — Add to Collection / Add
                                   Tag / Share / Move to Folder over the effective
                                   selection (feat/multi-select)
    OutsideClickDeselect.swift     0×0 NSView + window leftMouseDown monitor that
                                   clears the selection on any click outside the
                                   grid's enclosingScrollView (feat/multi-select)
    AspectRatioCache.swift         per-file aspect (h÷w) for layout: bulk DB
                                   width/height + ImageIO header fallback, off-main
    CollectionsPage.swift          dedicated Collections page (toolbar
                                   square.stack.3d.up): "Collections" header (back
                                   arrow, no edit/trash) + 4-up alphabetical card
                                   grid that resizes to fit, scrolls vertically
    CollectionsRow.swift           in-collection header only (back/rename/count/
                                   delete); the all-collections cards moved to
                                   CollectionsPage 2026-06-13
    TagChipsRow.swift              tag chips; filter + management. Scopes to the
                                   active collection's members inside one, else the
                                   folder (AppState.tagSourceFiles)
    MoodPickerView.swift           background popover (Light/Dark/Auto/Custom)
    InfoSheet.swift                ⓘ About-Muse modal (behavior + privacy)
    KeyCaptureView.swift           NSView arrow/return capture (hero flips)
    BreadcrumbView.swift           path breadcrumb (kept; not in toolbar)
    OpenWithMenu.swift             NSWorkspace registered apps via LaunchServices
    ImageDetailPanel.swift         fit/100% preview overlay
    QuickLookFallback.swift        QLPreviewView wrapper
    ViewerRouter.swift             AssetKind → viewer dispatch
    DuplicatesView.swift           review pane with delete-to-Trash
    Viewer/                        hero image viewer (HeroImageViewer, HeroStage,
                                   ViewerInfoColumn, backdrop, geometry, toast,
                                   PillFlow/PillRowModel)
      ShareButton.swift            macOS share sheet (NSSharingServicePicker)
                                   for the hero image
    Spatial/
      SeededRandom.swift           SplitMix64 + FNV-1a (kept: grid burn seed +
                                   hero). Cloud/Galaxy views + their layout files
                                   (Cloud*/Galaxy*/SimilarityLayout/SceneProjection)
                                   were removed 2026-06-13 — see session log.
  Components/
    SearchBar.swift                debounced FTS5 search, scoped to sidebar folder.
                                   Native NSSearchField (system focus ring, clear
                                   button, accessibility; appearance follows mood)
                                   wrapped in NSViewRepresentable (feat/multi-select)
    GridSelection.swift            pure selection math (single / Cmd-toggle /
                                   Shift-range → new set + anchor), unit-tested
                                   (feat/multi-select)
    MasonryGeometry.swift          pure masonry packing (frames + height) from
                                   aspect ratios — feeds GridView's virtualization
                                   (replaced the old MasonryLayout: Layout, deleted
                                   2026-06-13 — a custom Layout can't virtualize)
  Fluid/                           (legacy dir name; water ripple removed
                                   2026-06-13 and the burn-up delete SHADER
                                   removed too — NO Metal shaders remain in app)
    FadeOutModifier.swift          animatable staggered opacity fade for the
                                   delete sequence (replaced the BurnUp shader)
  Settings/
    SettingsView.swift             placeholder; real Preferences pane is
                                   future work
  Muse.entitlements                app-sandbox + user-selected.read-write +
                                   bookmarks.app-scope + iCloud Documents +
                                   network.client (Sparkle update fetch ONLY —
                                   added 2026-06-15; no other network use) +
                                   mach-lookup temporary-exception for
                                   <bundleid>-spks/-spki (so the sandbox can run
                                   Sparkle's installer XPC — see SUEnableInstaller-
                                   LauncherService in Info.plist)
MuseShareExtension/                (separate app-extension target) "Send to Muse"
                                   — Finder Share-menu extension; copies dropped
                                   files into the single iCloud folder, picked up
                                   by the existing FolderWatcher
```

## Conventions

- **GRDB writes are async** — use `try await queue.write { ... }` and
  `try await queue.read { ... }`. The synchronous overload exists but
  conflicts with the async one inside async contexts; pick one and the
  build will tell you fast.
- **GRDB rows are inserted as `var`** — `MutablePersistableRecord.insert`
  mutates `id` in place. `let` rows fail to compile.
- **Manual tags beat vision tags** on label conflict (Q32). Enforced
  via `UNIQUE(file_id, label)` + branching in `Indexer.unionTags` and
  `AnalyzePipeline.analyzeOne`. This is what makes automatic re-analysis
  safe — it can never undo a user's tag edit.
- **Analysis is automatic + incremental** — it runs after indexing for
  files whose `analyzed_hash` ≠ `content_hash` (new/changed only); never
  re-processes unchanged files. There is no user-facing "Analyze" button.
- **Files are never deleted, only moved to Trash** via
  `NSWorkspace.shared.recycle`. Don't `unlink` user files. Ever.
- **No editing UI** — every "edit this" path goes through Open With…
  (`NSWorkspace.shared.open(url, withApplicationAt: ...)`).
- **No network calls** — if you find yourself reaching for `URLSession`,
  stop. The sandbox doesn't allow it. Markdown/SVG viewers have hard
  guards against remote loads. New third-party deps must be audited
  for network surface.
- **AppState is @MainActor**. So is most of the data layer. Background
  work (hashing, Vision) goes through `Task.detached(priority:)` or
  the `Indexer` actor's queues.
- **SourceKit module errors are noise.** During edits you'll see
  "Cannot find type 'FileNode' in scope" and similar — they're cross-
  file resolution issues that disappear at build time. Always verify
  with `xcodebuild ... build` before assuming something's broken.

## Open product questions (none currently)

All Q1–Q33 from the plan are locked in, with two superseded by the
2026-06-12 session:

- **Q10 (analysis manual-only)** — superseded. Analysis now runs
  automatically after indexing, incrementally (stale `analyzed_hash`).
- **Q9 / Phase 7 (chat panel)** — retired. The differentiating version
  is tool-calling; the v1 context-prompted panel was removed. History
  holds it for when that phase happens.

Future product decisions should be recorded in
`docs/superpowers/plans/file-viewer-rewrite.md` (or a sibling plan doc)
before implementation.

## How to run

1. Open `Muse/Muse.xcodeproj` in Xcode 16+.
2. Build & run (Cmd+R). The app starts on a clean shell — click
   "Add Folder" in the sidebar to point Muse at any folder on disk.
3. Toolbar (left → right): sidebar toggle · sort · show-subfolders ·
   search (center) · Collections (square.stack.3d.up) · background mood ·
   ⓘ About. (The grid/cloud/galaxy view picker and the water effect were
   removed 2026-06-13; the clear-collection ✕ was removed in favor of back
   arrows.) Find Duplicates lives in the File menu; Pin/Unpin Folder and
   Remove Folder live in the Edit menu; analysis runs automatically.
4. Sandboxed container path:
   `~/Library/Containers/com.tarrats.Muse/Data/Library/Application Support/Muse/`.
   `muse.sqlite` there; wipe it to rebuild the schema on next launch.
5. ThumbnailCache lives beside it; capped at 2GB, LRU-evicted on launch.

## Status as of merge to main

- Branch state: `main` is now at the merged tip; `dev` is preserved at
  the pre-rewrite water-toggle commit (older); `feat/file-viewer-rewrite`
  is the source-of-truth branch for the rewrite progression.
- Test coverage: none. (Test suites are a separate workstream.)
- Known soft spots:
  - Code syntax highlighting (renders as plain monospaced for now).
  - iCloud Drive: dataless files are skipped on index/hash until
    downloaded (no empty-hash corruption); download-state badges deferred.
  - Saved smart searches (schema exists; UI is post-v1).
  - Archive browse-without-extracting (uses Quick Look).
  - Onboarding flow (separate design pass needed).
  - Settings/Preferences pane (placeholder only).
  - Top-edge "gradual blur" effect: attempted and reverted; prototype
    reference kept at `docs/superpowers/assets/gradual-blur-prototype.html`.
  - iCloud sidecar hydration — two inherent (by-design, not bugs) behaviors:
    (1) **OCR full-text search is degraded on hydrate-only devices.** Sidecars
    don't carry OCR text (large; intentionally excluded), so a device that only
    hydrated a file (never ran Vision locally) matches FTS on basename + caption
    only, not OCR'd text. The file is marked analyzed, so it won't re-Vision to
    recover OCR. Intent IS carried, so intent collections are unaffected.
    (2) **Duplicate identical content split across subfolders.** Sidecars live
    in a per-folder `.muse/` keyed by content hash; byte-identical files in
    different subfolders of the iCloud zone only get a sidecar beside the copy
    that was analyzed, so the other copy won't hydrate on a fresh device until
    its own analyze pass runs. A future fix would be a single zone-root `.muse/`
    index instead of per-folder.

## Working with this codebase

- Use the rewrite plan as the source of truth for "why does it work
  this way" questions.
- When in doubt about a product decision, the plan's locked Q-number
  table answers most of them.
- Keep commits scoped to a single phase or feature; the rewrite log
  is a useful reference and merging clean diffs preserves it.
