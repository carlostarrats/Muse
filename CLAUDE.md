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

- `docs/possible-updates.md` — low-priority, non-blocking backlog (cosmetic
  code tidiness + deferred decisions). Nothing here is a problem; fold items in
  opportunistically when shipping something else. Don't cut a release for them.

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
| Polish 12 — folder ops (new subfolder + rename w/ DB migration) + hero Share/Open-With dropdown + Info modal refresh | ✅ built, unmerged | `feat/folder-ops-and-share` |

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
  **(SUPERSEDED 2026-06-17:** tags are now per `(file_id, parent_dir)` — a
  duplicate in another folder has its own tags. See the per-file-tags session
  log.)
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

### Tag chip fixes + remove-from-tag/collection — 2026-06-16 (on `fix/tag-chip-count-overlap`, merged into `safety/icloud-dev-container-isolation`)

Live UI session on the tag chip row and grid context actions:

- **Tag chip count overlap fixed.** On hover the chip reveals its count; long
  labels (e.g. `illustration`, `people`) overlapped the number. Root cause: the
  chip only made room by shrinking its two neighbors, capped at a 50pt `floor`,
  so when neighbors were short it couldn't widen enough. Fix in `ChipFlow`
  (`TagChipsRow.swift`): the hovered chip now grows by an ADAPTIVE amount
  (`growForHovered` = measured count width + 5pt, so the word↔number gap is
  uniform for `1` and `1234`) and ALWAYS by the full amount; neighbors yield down
  to a 30pt floor and any shortfall widens the row (`sizeThatFits` returns the
  real width). No overlap regardless of label/count length.
- **All tags shown.** Removed the top-30 display cap (tags past 30 were
  unreachable — the chip row is the only tag browser). Row shows every tag in the
  current folder/collection, most-used first, alphabetical tiebreak, horizontally
  scrollable.
- **Remove from tag / collection.** Right-click a tile while viewing a tag →
  "Remove Tag «label»"; inside a collection → "Remove from Collection «name»".
  Menu-bar equivalents in Tags/Collections (gated to that context + a selection,
  excluded during search). Both act on the effective selection via new
  `AppState.removeTag(_:fromURLs:)` / `removeFromCollection(_:urls:)`.
  `TagStore.removeLabel` leaves `analyzed_hash` untouched so the auto-tagger
  never regenerates a removed tag; `CollectionStore.removeFile` records an
  exclusion so the removal sticks. When a removal empties the active tag OR the
  open collection, the view returns to All / the library in a single transaction
  (no stranded empty page).

### iCloud dev-container isolation (data-loss safeguard) — 2026-06-16 (on `safety/icloud-dev-container-isolation`)

Hardened against an iCloud purge risk inherent to app-private ubiquity
containers (the failure mode that lost files in another local-first app on
this same machine/Apple ID).

- **The risk.** Muse's single "Muse" folder lives in an app-private iCloud
  container (`iCloud.com.tarrats.Muse`, `NSUbiquitousContainerIsDocumentScope-
  Public = true`) and holds the user's *actual files* + `.muse` sidecars. The
  lifetime of an app-private container's Documents is tied to the app's install
  state: if macOS's `bird` daemon decides the app was uninstalled, it purges the
  container server-side (propagating the delete to every device). The trigger is
  instances of the bundle id repeatedly appearing/disappearing — exactly what a
  dev machine produces (DerivedData rebuilds, `/private/tmp` builds, mounted/
  unmounted release DMGs, Trash). `lsregister` showed dozens of `com.tarrats.Muse`
  bundles registered here, all claiming the one production container, built with
  mixed identities (adhoc / Apple Development / Developer ID).
- **The fix — isolate Debug from the production container.** Debug builds now
  sign with **`Muse/Muse-Debug.entitlements`** and **`MuseShareExtension/
  MuseShareExtension-Debug.entitlements`**, which are the production entitlements
  **minus the three iCloud keys** (`icloud-container-identifiers`,
  `icloud-services`, `ubiquity-container-identifiers`). So local dev builds no
  longer *claim* the container, and their constant churn can't mark it
  uninstalled. Verified: the built Debug app has no iCloud/ubiquity entitlements
  (sandbox + app group intact). `CODE_SIGN_ENTITLEMENTS` is set per-config in
  `project.pbxproj` (Debug → `-Debug` files, Release → the originals); signing is
  Automatic, and dropping a capability needs no portal change.
- **Production / App Store untouched.** Release keeps `Muse.entitlements` (with
  iCloud) exactly as before, so the Developer-ID build — and a future Mac App
  Store target, which would reuse the same bundle id + container — share one
  container and one set of user data. The isolation is Debug-only.
- **Other levers (already in good shape).** Updates ship via **Sparkle only**
  (atomic in-place swap preserves app identity — never instruct users to drag a
  new DMG over the old app). Eviction under storage pressure is NOT a data-loss
  path here: Muse already tolerates dataless iCloud files (skips them until
  downloaded), so the "keep-downloaded" marking isn't needed. Release builds are
  notarized + stapled by `release.sh`.
- **Operational note for the developer.** Don't run Release/DMG builds that claim
  the container any more than necessary, and eject release DMGs + empty Trash so
  phantom registrations don't accumulate. A backup of the container's current
  contents was taken to `~/Documents/Muse-iCloud-backup-<timestamp>/`.

### In-place edit refresh — change detection overhaul — 2026-06-17 (on `main`)

Fixed "I crop/edit an image (Apple Preview, Photoshop) and the thumbnail never
updates — not on edit, not even after removing + re-adding the folder." Root
cause was **four independent caches keyed purely by file path**, with no
content/mtime signal, so a file re-saved at the same path served stale data
forever. User requirement: **parity everywhere — local AND the iCloud "Muse"
folder must refresh identically.**

- **Root causes (all path-keyed, no change signal):** (1) `ThumbnailCache` key
  was `url.absoluteString | WxH@scale` — the on-disk PNG persists across launches
  AND folder remove/re-add (same URL → same key), so the old thumbnail was
  immortal. (2) The `FolderWatcher` reload passed `thenIndex: false`, so a live
  edit never re-indexed/re-analyzed/prewarmed — tags/colors/OCR/dimensions stayed
  frozen, and a newly-added file wasn't tagged until you reselected the folder.
  (3) `AspectRatioCache.resolved` is permanent per session, so a crop that
  changed proportions kept the old masonry frame. (4) iCloud files are never
  re-hashed by `Indexer.isUnchanged` (it trusts the stored hash because iCloud
  oscillates size/mtime), so iCloud edits didn't re-analyze at all.
- **The fix (forward code, mirrors the existing local/iCloud split):**
  - **`ThumbnailCache.invalidate(_ url:)`** drops mem + on-disk PNGs for every
    rendered variant (`renderedVariants` = 320@2, 160@2 — single source of truth),
    deleting disk **synchronously** so a re-fetch can't read the stale PNG back.
    The cache key now normalizes on `standardizedFileURL.path` (NOT absoluteString)
    so a tile's enumerated URL and an invalidate()/reconstructed-from-path URL hash
    to the SAME key (a one-time orphan+regen of old PNGs).
  - **`Indexer`** `reconcile`/`indexFile` now return `Bool` (true = in-place
    content change), and `indexBatch` returns the changed URLs + gained `force`
    (re-hash everything, skipping the size/mtime/known-hash shortcut) and `silent`
    (no progress pill) params. A pure edit-in-place also **clears `analyzed_hash`**
    so the analyze pass regenerates tags/palette/OCR/dimensions.
  - **`FolderWatcher`** now delivers the FSEvents **changed paths**; the pure,
    unit-tested `FolderEventFilter.mediaChanges(paths:folder:recursive:)` keeps
    only viewable files inside the folder (drops hidden / `.muse` sidecar dirs /
    out-of-folder / subfolder-when-shallow).
  - **`AppState`** gained `contentVersion: [path:Int]` + `contentToken(for:)` +
    `markContentChanged(_:)` (invalidate thumbnails + bump version). The grid
    tile's load `.task` is keyed on `TileLoadID(url, version)`, so a bump
    re-decodes the now-fresh bytes. `handleFolderEvent` force-re-hashes ONLY the
    specifically-changed media (works for both zones — driven by a real FSEvents
    write, including iCloud sync-in, not by polling oscillating metadata), drops
    their art, prewarms + re-analyzes (analyzePending self-gates on stale
    analyzed_hash → covers new AND edited), then reloads the listing for
    adds/removes/renames. No folder-wide reindex per event.
  - **iCloud cold-start parity (edits made while Muse was closed):** a fresh
    folder selection runs a **background, silent, content-hash** verify pass
    (`scheduleIndexing(verifyICloud:)` → `indexBatch(force:silent:)`) over the
    iCloud-zone files; only genuinely-changed files get art dropped + re-analyzed.
- **OVERRIDE of prior guidance (deliberate, user-directed):** the old rule "do
  NOT re-check iCloud files; trust the stored hash" was about **size/mtime**
  comparison (which oscillates and would re-index the whole folder every visit).
  This change does NOT reintroduce size/mtime for iCloud — it uses **content
  hashing** (reliable) driven by FSEvents (live) + a background verify (cold
  start). The trade-off is real: the cold-start verify re-reads downloaded iCloud
  files' bytes once per folder-open (background/silent). Accepted for parity.
  Live edits in BOTH zones are cheap + reliable via FSEvents.
- Tests: `FolderEventFilterTests` (pure path filter). Full suite green; Debug
  build green.
- **QA review pass (fixed):** (1) the FSEvents callback cast `eventPaths` via
  `unsafeBitCast(_, to: NSArray.self)`, but without `kFSEventStreamCreateFlagUseCFTypes`
  the framework delivers a raw C `char**` — undefined behavior (crash/garbage)
  on the FIRST file change. Added the flag so `eventPaths` is a CFArray of
  CFString (toll-free bridged). (2) `contentVersion` is now reset on a fresh
  folder load so it can't accumulate across a long session (the on-disk
  thumbnail is path-keyed and already regenerated on edit, so the reset can't
  strand stale art).

### Sort-direction toggle — 2026-06-17 (on `feat/in-place-edit-refresh`)

Every sort mode was locked to one direction (date→newest, name→A→Z, size→largest).
Added a toolbar **direction arrow** immediately right of the sort menu that flips
the active mode's order. `AppState.sortReversed` (+ effective `sortAscending` =
`defaultAscending` XOR reversed) feeds a new `reversed` param on
`SmartSorter.apply` (it reverses the fully-ordered array — uniform across all
modes incl. Color/Shape). `SortMode.defaultAscending` drives the arrow (up =
ascending); `SortMode.directionLabel(ascending:)` gives the mode-aware tooltip
("Newest first"/"Oldest first", "A → Z"/"Z → A", …). The toggle is global (not
per-mode) and disabled on the Collections page like the sort menu. Tests:
`SortDirectionTests`. Build + suite green.

### Cosmetic tidy-ups — 2026-06-17 (on `feat/in-place-edit-refresh`)

Cleared the two `docs/possible-updates.md` code-tidiness items (pure refactors,
no behavior change; build + full suite green):

- **Split `AppState.swift`** (1012 → 782 LOC). Grid multi-selection moved to
  `AppState+Selection.swift`; tag/collection filtering moved to
  `AppState+Filters.swift`. Stored `@Published` state stays in the core class
  (extensions can't hold stored properties); the only access change was making
  `collectionRequestToken` / `tagRequestToken` internal (Swift `private` is
  file-scoped, so the moved methods couldn't otherwise reach them). Methods moved
  verbatim. `@MainActor` isolation propagates to same-module extensions, so no
  re-annotation needed.
- **Renamed `Muse/Fluid/` → `Muse/Effects/`** (held only `FadeOutModifier.swift`;
  the water/burn shaders are long gone). No code or pbxproj references — it's a
  filesystem-synchronized group, so the `git mv` is the whole change.

### Collection delete (no Hide) + auto-organization opt-outs — 2026-06-17 (on `feat/collections-delete-and-settings`)

Removed the confusing "Hide Collection" action and added Preferences toggles to
stop forcing auto-organization on the user.

- **Delete replaces Hide.** Right-clicking a collection card now offers
  **Delete Collection…** (warning modal) instead of "Hide Collection"; the
  in-collection trash button uses the same path. Both call
  `CollectionStore.setHidden(true)` — the durable suppression that survives
  reclustering — because collections are AUTO-GENERATED: a plain row-delete
  (`CollectionStore.delete`) silently regenerates on the next analyze (stable
  intent ids re-insert; emergent clusters re-match), whereas `is_hidden`
  persists (the recluster upsert never touches it, and `currentMembership`
  still anchors the cluster identity). The `is_hidden` flag is now purely an
  internal "don't auto-rebuild" tombstone — there is NO user-facing hide, no
  hidden-collections list, no un-delete. (`CollectionStore.delete` is now
  unused by the UI but kept.)
- **Auto-organization is opt-out** (`AppSettings`, two `UserDefaults` keys,
  both default ON, surfaced in the Preferences window). "Automatically tag new
  images" gates `AnalyzePipeline.analyzePending` (all three automatic callers:
  folder load + folder-watcher events); "Automatically organize into
  collections" gates `CollectionsEngine.recluster` (covers the analyze-pass and
  IntentBackfill triggers). Off → newly indexed folders stay viewable but are
  not auto-tagged/clustered; **existing tags/collections are untouched** (the
  toggle gates only the automatic pass, and analysis is incremental), and the
  **manual** paths still work (Analyze / Regenerate Tags; hand-made
  collections). Global + future-only by construction — no per-folder state.
- **Hand-made collections.** A **+** button beside the Collections-page header
  creates an empty collection auto-named "Collection N"
  (`ManualCollectionName.next` = one past the highest existing "Collection N",
  pure + tested) via `CollectionStore.createManual` (model_version='manual', so
  it's protected from reclustering/pruning). `fetchAll` now keeps EMPTY manual
  collections visible (auto collections with nothing on disk stay hidden), so a
  fresh one shows up and can be populated with the existing "Add to Collection"
  selection action; rename via the in-collection header. `HeaderIconButton` is
  now non-private (the page reuses it).

### Per-file tags — identity de-welding — 2026-06-17 (on `feat/per-file-tags`)

Fixed "deleting a tag in one folder removes it from a duplicate in another
folder," and removed the library-wide tag delete. Root cause: tags hung off
`file_id` (content hash), so byte-identical files in two folders shared ONE
set of tag rows (documented previously as an invariant — the user considers
it a bug). Proven live: 12 welded identities, e.g. a flavicon screenshot at
3 paths sharing 7 tags. Spec:
`docs/superpowers/specs/2026-06-17-per-file-tags-design.md`.

- **Decision — tags belong to `(file_id, parent_dir)`** (the file IN its
  folder), not to content alone. `TagScope` is the single source of truth for
  the parent-folder key. Chosen over per-path-id because rename-in-place then
  preserves tags for free (same content + same folder) while a duplicate in
  another folder is independent — no fragile rename detection. Edit-in-place
  resets tags (hash changes → new scope), matching the existing edit-refresh.
- **Part A (shippable alone):** removed `TagStore.deleteLabel`
  (`DELETE FROM tags WHERE label = ?`, library-wide) that the right-click
  tag-chip "Delete Tag" called. It now deletes only the current view's files
  (`tagSourceFiles`) via the existing scoped path; dialog copy updated.
- **Part B:** migration `v7_tag_parent_dir` adds `parent_dir`, fans each
  existing tag out across the distinct alive parent folders of its `file_id`
  (preserves everything currently visible; first scope reuses the original
  id), and swaps `UNIQUE(file_id,label)` → `UNIQUE(file_id,parent_dir,label)`.
  `TagStore` reads/writes scope by `parent_dir`; `deleteAllTags`/`removeLabel`
  no longer leak to duplicates. `AnalyzePipeline` writes vision tags per alive
  folder, the regenerate "tagless" gate is per-folder, and the sidecar exports
  only its folder's tags. `Indexer.unionTags` is folder-aware; a brand-new
  duplicate path inherits the file's VISION tags for its own folder (manual
  tags are not inherited — they're per-folder). `TagChipsRow` aggregation +
  `setActiveTag` grid filter scope by folder.
- **Scope note (deliberate):** only TAGS are per-file. Content-derived
  metadata (palette/caption/dimensions/intent/feature_print/FTS/embeddings)
  stays keyed by `file_id` — identical for identical pixels, not user-editable,
  and auto-splits on edit. Making it per-file would mean tearing down
  `content_hash UNIQUE` (dedup, iCloud sidecar, FTS, embeddings) for zero
  observable difference. SearchService tag-match still resolves all copies of
  a matching file_id (shared with FTS/semantic) — left as-is (accepted).
- **Verified on the live DB:** 0 of 8116 (file_id,label) pairs lost after
  migration; the welded flavicon screenshot's 7 tags are now independent in
  Desktop/flavicon, Saved Inspo, and .Trash/flavicon. Tests: `TagScopeTests`,
  `TagParentDirMigrationTests`. Debug build + full `MuseTests` suite green.
- **QA review pass (fixed):** an adversarial multi-agent review found ONE
  remaining `file_id`-only tag read that reached the UI — `ViewerFileDetails`
  (the hero viewer's tag panel) showed the UNION of a duplicate's tags across
  folders AND its remove-pill (deletes by row id) could delete a tag belonging
  to another folder's copy. Now scoped by `parent_dir`
  (`testTagsScopedToFolderNotDuplicate`). Also dropped a redundant
  `tags_file_id_idx` and added `TagFolderScopeTests` for the new
  `inheritVisionTags` / `unionTags` per-folder behaviors. A second review round
  confirmed the leak class is fully closed (every tag path scoped or a
  documented global) with build + suite green.

### Three small fixes: deselect parity · PDF filenames · double-click on old Macs — 2026-06-17 (on `feat/next-9`)

A live bug/feature pass — three independent fixes, build + full `MuseTests`
suite green, each adversarially reviewed (two parallel reviewers, no blockers/
majors found):

- **Deselect parity, no-tags vs tags** (`GridView.swift`). Clicking the empty
  strip at the top of the grid deselected the current image when the folder had
  tags but NOT when it had none. Root cause: that strip is only a reliable
  deselect zone when the tag-chip row occupies it — the chip row sits OUTSIDE
  the grid scroll view, so `OutsideClickDeselect` (the AppKit mouse monitor)
  fires there. With no tags the chip row collapses (`fix/grid-top-inset-no-tags`
  raised the images) and that strip becomes live grid top-inset, whose only
  deselect was the ScrollView `.background` tap — viewport-pinned and unreliable
  for in-content clicks (which is exactly why `masonryCanvas` already adds its
  OWN `Color.clear` deselect behind the tiles). Fix: wrap the scroll content in
  a `ZStack` with a content-level `Color.clear` deselect surface spanning the
  full content (`minHeight: geo.size.height`), BEHIND the tile VStack — tiles
  keep their own select taps (they're in front; SwiftUI hit-tests front-to-back,
  so no tile/drag swallowing), empty space clears. Deselect is now identical
  with or without tags. No scroll-behavior regression (`minHeight` grows the
  ZStack to the taller of viewport vs. real content; never forces extra scroll).
- **Filenames under images in the collection PDF** (`CollectionPDFLayout.swift`,
  `CollectionPDFExporter.swift`). Each image in the exported 11×14 PDF now shows
  its filename centered below it, end-truncated with an ellipsis (`…`) via
  CoreText `CTLineCreateTruncatedLine` so it never exceeds the image width or
  wraps to a second line. `Geometry` gained `captionHeight` (defaulted to 0 —
  existing tests/behavior untouched); `paginate` reserves that strip per tile
  (whole-tile height = `columnWidth*aspect + captionHeight`, still capped to one
  page) so captions never collide with the next masonry row. The exporter splits
  each placement rect into image area (top) + caption strip (bottom) and draws
  the caption with CoreText only (off-main-safe). Verified end-to-end by
  rendering a sample PDF (long names truncate, Unicode names render, short names
  show in full). Tests: `testCaptionHeightReservedPerTile`,
  `testCaptionedTilesStayWithinPageAndPlaceEveryImage`.
- **Double-click-to-open failing on older Macs in tag/collection views**
  (`GridView.swift`). A friend on a 2018 Intel MacBook Pro (Sequoia) couldn't
  open an image by double-clicking inside a tag-filtered grid — nothing
  happened. Root cause: `handleTileTap`'s manual double-click detector measured
  the gap with `Date()` sampled when the HANDLER runs. On slow hardware the
  first click's selection stalls the main thread; the second click's handler is
  then delivered late, so `Date()` timed the handler latency (>0.35s) instead of
  the user's actual click cadence, and the double-click was dropped. Fix: measure
  from the originating event's hardware timestamp (`NSApp.currentEvent?.timestamp`,
  seconds since boot — immune to the stall; fallback `ProcessInfo.systemUptime`,
  same clock) and widen the window to `max(NSEvent.doubleClickInterval, 0.35)`
  (honors the user's System Settings double-click speed, never stricter than
  before). This is the ONLY double-click-to-open path (shared by the main grid
  and the in-collection grid), so collections are covered too; collection CARDS
  open on a single tap and were never affected. Not reproducible on Apple Silicon
  (the main thread never stalls long enough) — a pure timing fix that removes the
  hardware dependency rather than just widening a threshold.

### Cross-folder views drop the sidebar highlight + search scope picker — 2026-06-17 (on `feat/next-9`)

The sidebar kept a folder visually selected even inside the Collections page /
a single collection (both cross-folder, library-wide views), implying the
current folder mattered when it didn't. Fixed, plus a related search-scope
control. Build + full `MuseTests` suite green; two parallel adversarial reviews
(no blockers/majors — one review-found `select(folder:)` issue fixed below):

- **No folder highlight in cross-folder views** (`SidebarView` `isSelected`).
  Returns false on the Collections page, inside a single collection, AND during
  a library-wide ("All") search. A "This folder" search keeps the highlight (the
  folder IS the scope). `selectedFolder` itself is untouched, so Back/clear
  restores it. The drag-to-move drop-target highlight (`dropTargeted`) is
  independent of `isSelected`, so folders stay drop targets in a collection.
- **Tapping a folder exits any cross-folder context** (`AppState.select(folder:)`).
  Now also clears `showingCollections` + `activeCollectionID` (leaves a
  collection / the Collections page), ends any active search inline (NOT via
  `clearSearch()`, which would double-reload — a review-found fix; a stale search
  otherwise left the query in the field, the grid on results, and the folder
  un-highlighted), and resets `searchAllFolders` to the folder default. Lands on
  the folder's normal "All" view. (Going Back instead still returns to the
  previously-selected folder — `selectedFolder` was always preserved.)
- **Search scope picker** (`SearchBar`, `AppState.searchAllFolders` + `runSearch`).
  The search field's magnifier dropdown (native `searchMenuTemplate`, no recents)
  offers **All** vs **This Folder**. Default stays **This folder** (no change to
  prior default behavior — search was already folder-scoped); "All" searches the
  whole indexed library and suppresses the folder highlight. Switching scope
  re-runs an active search. `searchAllFolders` persists across search clears but
  resets when you navigate into a folder. The 250ms debounce is cancelled on an
  external query-clear so a just-dismissed search can't re-fire.
- **Search field text inset** (`InsetSearchField`/`InsetSearchFieldCell`): the
  editable text starts ~4px right of the system default via a `searchTextRect`
  override. (The magnifier + menu chevron are ONE system-drawn glyph — the gap
  between them isn't adjustable from layout rects, so that was left native.)

### Transition smoothness + folder-switch perf + tag-chip model refactor — 2026-06-17 (on `feat/next-10`)

A long live-tuning + profiling + refactor pass on page/folder transitions and
the folder-switch latency. Build + full `MuseTests` suite green; two independent
adversarial reviews + a fix-verification pass (the one MAJOR they found is fixed
and re-verified — see below).

- **Unified, snappier nav crossfades.** All navigation transitions now share one
  short duration, `AppState.navTransition` (0.2s): the Collections-page⇄grid
  swap, the collection/tag filter swaps, search enter/exit. (Mood 0.35s and the
  hero-viewer open/close 0.18s are NOT nav transitions — left as-is.)
- **`AppState.visibleFiles` memoized.** It was a computed property re-running the
  tag filter (standardizing ~1700 paths) on every access, and the grid reads it
  several times per render + on every layout recompute. Now cached, invalidated
  via `didSet` on its four inputs (`currentFiles`, `activeCollectionFiles`,
  `activeTagPaths`, `isSearchActive` — in-place Optional/array mutations fire
  didSet too, so it can't go stale).
- **Collections→folder no longer "ghosts."** The page swap is a fade-THROUGH,
  not a blend: `ContentView.pageReveal` = `.asymmetric(insertion: .opacity,
  removal: .identity)` — the outgoing screen is removed INSTANTLY and only the
  incoming fades in, so the two dissimilar layouts never double-expose. The
  ambient `.animation(value:)` on `isCollectionsPage`/`activeCollectionID` were
  removed; those transitions are now driven explicitly by `withAnimation` inside
  `toggleCollectionsPage`/`setActiveCollection`/`setActiveTag` (the `isSearchActive`
  + mood ambient animations stayed).
- **Folder switch tears the old view down INSTANTLY.** `setActiveTag` /
  `setActiveCollection` gained an `animated` param; `select(folder:)` clears the
  old tag/collection/page with `animated: false` (no `withAnimation`), so the old
  view vanishes in ONE frame instead of animating away in visible steps (tags
  collapsing → content sliding up → page leaving) before the new folder appears.
- **The grid loads the nav first, then the images — no shove-down.** A tagged
  folder used to render its images at the top and then get pushed down when the
  chips appeared. Now the folder load computes the tag chips in the SAME off-main
  pass as enumeration and publishes files + chips together, so the chips are
  sized when the images first render. `tagRowReady` is a gate that holds the
  images only during the brief fresh-load window (default TRUE — every other
  context renders immediately; set false at the top of
  `reloadCurrentFiles(showLoading:)` and back true in that method's inline
  publish). During enumeration the grid shows the calm background (the old
  masonry skeleton was removed — it sat where the tag row later shifts).
- **Tag-chip loading moved into the MODEL (the big refactor, both speed + code
  health).** The chips used to load themselves inside `TagChipsRow` via a
  `.task(id: reloadKey)` that ran a DB query — a ~52ms SwiftUI round-trip on
  every folder switch (publish files → re-render → the view's task wakes →
  query → reveal). Now:
  - `TagChipLoader` (new, `Database/`) is the SINGLE shared query logic: a fast
    single-folder `GROUP BY` path (one constant `parent_dir`) + the general
    per-file-scope path (collections / recursive). Pure, nonisolated, sync reads.
  - `AppState` owns `tagChipRows` (`@Published`) + `reloadTagChips()`; the fresh
    folder load computes them inline (the round-trip is gone), and a `$tagsVersion`
    sink + `setActiveCollection` + `removeFromCollection` + deletion
    onRemove/onRestore + `removeRoot` are the other triggers. `TagChipsRow` is now
    a pure renderer of `appState.tagChipRows` (no DB code).
- **Measured folder-switch latency** (warm, ~2k-file tagged folder, profiled with
  temporary stderr instrumentation, since removed): tag query 53ms→12ms
  (GROUP BY), enumeration 47ms→40ms (skip `AssetKind.detect`'s redundant per-file
  `fileExists` stat via `FileNode(url:kind:)` + `AssetKind.classify`), and the
  ~52ms SwiftUI round-trip eliminated by the inline-chips refactor → total gap
  ~120ms → ~60ms. (First-touch-per-session is still ~3× slower — cold OS
  filesystem/thumbnail/DB caches; that's physical I/O, not optimized. The OS
  cache survives app quit/relaunch but not a reboot/memory-pressure.)
- **QA — two adversarial reviews + a verification pass.** Review found ONE major:
  opening a collection before any folder had loaded showed a blank grid, because
  the gate (`tagRowReady`) was only ever set true by the folder-select path.
  Fixed by defaulting `tagRowReady = true` and deleting the never-used `reveal:`
  parameter from `reloadTagChips`. A follow-up review confirmed the fix and that
  a superseded/cancelled fresh select can't leave the gate stuck (the false-set
  is synchronous at method entry; only the token-winning select publishes, always
  setting it true). Remaining items are minor + pre-existing (auto-analysis
  doesn't refresh chips until a folder revisit; a cross-chunk duplicate
  over-count) — identical to the old code, not regressions.

### Grid file names + native macOS file visuals — 2026-06-17 (on `feat/next-11`)

Two related grid changes (spec:
`docs/superpowers/specs/2026-06-17-grid-file-names-design.md`, plan:
`docs/superpowers/plans/2026-06-17-grid-file-names.md`). Built via subagent-
driven development (3 tasks, each task-reviewed + a final whole-branch review);
build + full `MuseTests` suite green.

- **Non-image tiles now show the real macOS visual.** The grid's non-image card
  path used to render a flat SF Symbol and *ignore* the fetched QuickLook
  thumbnail entirely. Root fix is two parts: (1) `ThumbnailCache.generate()`
  requests `representationTypes: .all` (was `.thumbnail`) from
  `QLThumbnailGenerator`, so `generateBestRepresentation` returns a real CONTENT
  preview when one exists (PDF first page, text/office doc render) AND falls back
  to the native macOS TYPE ICON (zip/dmg/app, vector-backed multi-res) instead of
  nil → grey tile; content is still preferred over the icon, so files that
  already rendered are unchanged. (2) `GridView`'s `TileView` now DISPLAYS that
  image (`cardIcon` → `Image(nsImage:)`, `scaledToFit`, centered), with the SF
  Symbol kept only as a transient loading/failure fallback. Video/audio cards
  also get their QuickLook preview now.
- **"Show file names" setting** (`AppSettings.showFileNames`, key `showFileNames`,
  default **OFF**; surfaced in the Preferences "Grid" section). OFF (default):
  photos show no text; non-image cards show the icon centered with the filename
  INSIDE near the bottom (single line, tail-ellipsis, width = tile width). ON:
  every tile gets the filename caption BELOW it and non-image cards drop the
  internal name (icon only). Toggling re-packs the grid live.
- **Layout via `MasonryGeometry.captionHeight`** — a new trailing `captionHeight:
  CGFloat = 0` param adds a fixed strip (≈18pt, constant across column counts) to
  each tile's frame height, mirroring `CollectionPDFLayout.captionHeight`. Frames
  stay the single source of truth, so virtualization is untouched; `TileView`
  splits the frame into an image area (top) + caption strip (bottom). The
  selection accent wash+border wraps the **image area only** (Finder-style; the
  caption sits below it, unbordered), and the hero open/close flight reads the
  image-area global frame. `AspectRatioCache` is unchanged (non-image cards keep
  their fixed `1/1.4` aspect; the caption is added uniformly by the geometry).
- **All grid tiles are square-cornered.** The non-image cards' grey backing was
  briefly rounded (cornerRadius 8); changed to square (`Rectangle()`) to match
  the edge-to-edge photo tiles — clipShape, selection overlay, and the card fill.
- **Collection-PDF export is deliberately untouched** — it always renders
  filenames regardless of the setting (`Export/CollectionPDFLayout.swift` /
  `CollectionPDFExporter.swift`). Tests: `MasonryGeometryTests` (caption-strip
  reservation, totalHeight, no-overlap, captionHeight:0 regression).

### Grid hover + selection redesign — 2026-06-17 (on `feat/next-12`)

Reworked the grid tile's hover + selection feel (spec:
`docs/superpowers/specs/2026-06-17-grid-selection-redesign-design.md`, plan:
`docs/superpowers/plans/2026-06-17-grid-selection-redesign.md`). Build + full
`MuseTests` suite green; final visual values tuned live with the user.

- **Hover → a calm dark veil, no grow.** The old `scaleEffect(1.025)` hover-grow
  is gone. An unselected tile on hover now gets a subtle black veil
  (`hoverVeilOpacity = 0.2`) over the image, no size change. A hovered, already-
  selected tile keeps only the selection look (veil gated on `!isSelected`).
- **Selection → a padded, mood-adaptive ring (not the old flush accent).** The
  old edge-to-edge `accentColor`-0.22 wash + 3pt accent stroke is replaced: the
  image **shrinks** inward (`selectionInset = 10`pt per side, keeping its natural
  aspect — only the CORNERS are square, the image is NOT forced to 1:1), the
  revealed gap shows the app background (`moodPalette.background`, same as the
  grid gutter), and a slightly-rounded ring (`ringCornerRadius = 8`,
  `ringWidth = 2.5`, `ringInset = 0` so it hugs the tile edge) is stroked around
  it with a subtle color tint (`selectionTintOpacity = 0.18`) over the image. All
  in `TileView.imageContent` (now a `ZStack`: bg fill → padded image+tint →
  hover veil → ring). The tile FRAME, masonry packing, virtualization, hero
  open/close frame reporter, VoiceOver `.isSelected`, drag, and double-click are
  untouched — only the image's displayed size changes within the fixed frame.
- **Ring/tint color is a whole-grid rule from the background mood** (NOT
  per-image), in the pure `Models/SelectionStyle.swift` (`SelectionAccent` +
  `SelectionStyle.accent(forBackground: MoodRGB)`): a **neutral** background
  (Light/Dark/Auto, plus any low-saturation Custom — HSB saturation <
  `colorfulSaturationThreshold = 0.20`) → `Color.accentColor` (blue, today's
  look); a **colorful** Custom mood → black OR white, whichever has the higher
  WCAG contrast against the background (the max of the two always clears AA
  4.5:1), so the ring never vanishes into a same-hue background. Tests:
  `SelectionStyleTests` (neutral→blue, light-colorful→black, dark-colorful→white,
  chosen ring clears AA on a spread of saturated colors).
- **The visual magic numbers are locked production constants** (the `Self.`
  `private static let`s on `TileView`) — dev-tuned then hardcoded, no settings
  UI (the user explicitly wanted no in-app controls).

### Folder ops (new subfolder / rename) + hero Share dropdown — 2026-06-17 (on `feat/folder-ops-and-share`)

Spec: `docs/superpowers/specs/2026-06-17-folder-ops-and-share-dropdown-design.md`,
plan: `docs/superpowers/plans/2026-06-17-folder-ops-and-share-dropdown.md`.
Build + full `MuseTests` suite green.

- **New Subfolder + Rename Folder** in the sidebar (right-click) and the Edit
  menu. Both use **dialog prompts** (matching "Rename Tag…"), routed through
  `AppState.newSubfolderRequest` / `folderRenameRequest` + a single host
  `.alert` block on `ContentView` (so the context menu and menu command share
  one dialog). New Subfolder is offered on **every** folder incl. the iCloud
  "Muse" home (users may nest there); Rename is offered on every user folder
  **except** the iCloud home (it's app-managed). Top-level creation stays
  add-existing-only via the **+ Add Folder** button — there is deliberately no
  "new empty folder at the top level."
- **Pure ops** in `Filesystem/FolderOps.swift` (`sanitize` / `createSubfolder` /
  `rename` → `Result<URL, OpError>`; rejects empty / "/" / ":" / "." / "..",
  never overwrites on collision, rename-to-same-name is a no-op success).
  Roots already hold RW security scope, so create/move need no per-op scope.
- **Rename migrates the DB so nothing is orphaned.** A successful disk rename
  rewrites the stored **path prefixes** in `paths.absolute_path` and
  `tags.parent_dir` (`AppState.migratePaths`, one `queue.write`), so manual
  tags survive (tags are keyed `(file_id, parent_dir)`). Collections / FTS /
  analysis are `file_id`-keyed (content hash) and need no migration. The prefix
  match uses `SUBSTR(col,1,LENGTH(:old)+1) = :old || '/'` (plus exact `= :old`),
  **not** `LIKE`, so "%"/"_" in paths can't break it and a sibling like
  "…/OldStuff" is never caught by old "…/Old". The pure rewrite rule is
  `FolderRenameMigration.rewrite(path:old:new:)` (unit-tested independently of
  SQLite; the SQL applies the identical rule).
- **Tree refresh.** `FolderNode` gained a weak `parent` ref + `reloadChildren()`
  (re-reads children even when already loaded). Subfolder rename →
  `node.parent?.reloadChildren()`; **root** rename →
  `BookmarkStore.rootRenamed(_:to:)` mints a fresh security-scoped bookmark from
  the new URL (the inode-based old scope still covers the moved folder), swaps
  access, and updates the stored `Root` display name → the `$roots` sink
  rebuilds the sidebar. If the renamed folder was selected, it's reselected by
  URL after the rebuild.
- **Native-style Open With (shared).** `OpenWithItems` (in `OpenWithMenu.swift`)
  renders the registered apps with their **real macOS icons** (`NSWorkspace.icon`),
  the **default app first + marked "(default)"**, and an **"Other…"** picker —
  reading like Finder's submenu. The app list is computed **synchronously** in
  the body: a context-menu `.task` doesn't fire reliably, which is why the grid
  tile's "Open With" submenu was empty before (only "Open" / "Reveal" showed).
  Both the grid tile context menu (`OpenWithMenu`) and the hero Share dropdown
  reuse `OpenWithItems`.
- **Hero Share → dropdown.** `Views/Viewer/ShareButton.swift` is a `Menu`
  (styled like `ShareCollectionButton`): **Share** (unchanged
  `NSSharingServicePicker`), **Open**, and **Open With ▸** (`OpenWithItems`).
  The 38pt glass circle + icon are unchanged at rest.
- **Menu-bar parity.** File menu gained **Open** + **Open With ▸** for the
  selected single image. The grid right-click **Open With** is the shared
  `GridView` menu (covers the main, tag, and in-collection grids).
- **New Subfolder does not navigate.** After creating, the sidebar reveals the
  new folder (parent reloaded + expanded) but the grid stays on the current
  folder — `createSubfolder` no longer selects the new child.
- **Info modal** refreshed + enlarged (540×640 → 600×720): folders
  (new subfolder/rename/reorder/pin/remove), multi-select + grid actions,
  hero Open With, collection-PDF share, search scope, sort direction, grid file
  names/density, a new **Settings** section (auto-organization opt-outs), and a
  fix to the stale Updates copy ("it asks first" — the consent prompt was
  removed; checks are silent).
- Tests: `FolderOpsTests`, `FolderRenameMigrationTests`.

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
                                   current files, selected file, sort mode +
                                   direction, search, mood, watcher, indexing.
                                   The stored @Published state + folder/roots/
                                   search/watcher/indexing logic; filter + grid-
                                   selection methods split into the extensions
                                   below (2026-06-17 tidy-up). reloadAfterMove;
                                   allTagLabels preload (feat/multi-select).
                                   Memoized visibleFiles; navTransition (0.2s
                                   shared nav-crossfade duration); owns the tag-
                                   chip data — tagChipRows + reloadTagChips()
                                   (computed inline by the folder load so files +
                                   chips publish together); tagRowReady gate
                                   (feat/next-10)
    AppState+Selection.swift       extension: grid MULTI-selection (selectedFiles:
                                   Set<String> of paths + anchor) — applyClick /
                                   clearSelection / selectAllVisible /
                                   effectiveSelectionURLs / selectionOrder
    AppState+Filters.swift         extension: collection + tag-chip filtering —
                                   visibleFiles / tagSourceFiles / setActive-
                                   Collection / setActiveTag / removeTag /
                                   removeFromCollection / setCollectionCover /
                                   toggleCollectionsPage / bulkTagCommandsAvailable
    AssetKind.swift                kind enum + extension/UTType detection;
                                   classify(url:) skips detect's fileExists stat
                                   (used by FolderReader for fast enumeration)
    FileNode.swift                 in-memory enumerated-file value type;
                                   init(url:kind:) takes a precomputed kind so
                                   enumeration skips the per-file fileExists stat
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
    FolderOps.swift                pure create/rename folder on disk (sanitize +
                                   createSubfolder + rename → Result<URL,OpError>);
                                   no overwrite on collision (feat/folder-ops-and-share)
    FolderRenameMigration.swift    pure path-prefix rewrite for a folder rename
                                   (the rule AppState.migratePaths applies in SQL
                                   to paths.absolute_path + tags.parent_dir)
    BookmarkStore.swift            UserDefaults-backed root bookmarks; lifecycle
                                   start/stop access for sandbox. rootRenamed(_:to:)
                                   repoints a renamed root's bookmark + display name
    FolderTree.swift               lazy hierarchical tree + FolderReader; FolderNode
                                   has a weak parent + reloadChildren() (refresh after
                                   create/rename — feat/folder-ops-and-share)
    FolderWatcher.swift            FSEvents-backed live watcher; delivers the
                                   changed paths. FolderEventFilter (pure) keeps
                                   only viewable in-folder files (drops hidden/
                                   .muse/out-of-folder) — see 2026-06-17 session
    StarStore.swift                SQLite-backed starred folders
    ThumbnailCache.swift           QLThumbnail + AVAssetImageGenerator (videos);
                                   off-main, ordered (top→bottom) load; 2-tier
                                   cache (NSCache 512MB cost + on-disk LRU 2GB).
                                   Key normalized on standardized path; invalidate(_:)
                                   drops mem+disk for all renderedVariants so an
                                   in-place edit regenerates (2026-06-17). Non-image
                                   path requests QuickLook .all → real macOS type
                                   icon / content preview, not just .thumbnail
                                   (feat/next-11)
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
    TagScope.swift                 parent-folder key derivation — tags are
                                   per (file_id, parent_dir), not per content
                                   hash (2026-06-17). Single source of truth used
                                   by the migration, TagStore, AnalyzePipeline
    TagStore.swift                 manual/vision tag CRUD scoped by (file_id,
                                   parent_dir); library-wide rename (spelling)
                                   kept, library-wide DELETE removed (2026-06-17)
    TagChipLoader.swift            single shared query logic for the grid's tag-
                                   chip labels (fast single-folder GROUP BY +
                                   general per-file-scope path). Pure/nonisolated;
                                   AppState owns + calls it, the view only renders
                                   the result (feat/next-10)
    Housekeeping.swift             launch prune: index data for files unreachable
                                   from any sidebar folder, unseen >180 days
  Indexing/
    HashService.swift              streaming SHA-256; nil on dataless iCloud reads
    Indexer.swift                  identity reconciliation matrix (§4); size+mtime
                                   fast path; skips not-downloaded iCloud items.
                                   reconcile/indexFile return "content changed",
                                   indexBatch returns changed URLs + force/silent
                                   (re-hash for edits + iCloud verify) (2026-06-17)
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
                                   (feat/multi-select). No folder shows as selected
                                   in cross-folder views — Collections page, a
                                   single collection, or an "All"-scope search
                                   (2026-06-17); the drop highlight is independent
    GridView.swift                 VIRTUALIZED masonry grid — precomputes tile
                                   frames (MasonryGeometry from AspectRatioCache)
                                   and renders only viewport tiles (+overscan);
                                   column-count slider; tiles fade in as thumbs
                                   land. The ONLY grid view (cloud/galaxy retired
                                   2026-06-13; water effect removed 2026-06-13).
                                   Click = select (instant; Cmd toggles, Shift
                                   ranges), double-click opens (gap timed from the
                                   EVENT's hardware timestamp, not Date() at
                                   handler-run, so a main-thread stall on slow Macs
                                   can't drop it — 2026-06-17); accent wash+border
                                   inside the tile (scales w/ hover); .onDrag carries
                                   the file URL; selection-aware contextMenu
                                   (feat/multi-select). A content-level Color.clear
                                   deselect surface behind the tiles makes the empty
                                   top inset deselect with OR without the tag chips
                                   (2026-06-17). Non-image tiles render the native
                                   macOS icon/preview (cardIcon, SF Symbol only as a
                                   loading fallback); optional "Show file names" caption
                                   below each tile (MasonryGeometry.captionHeight strip;
                                   internal card name when off) — all tiles square-
                                   cornered (feat/next-11)
    SelectionMenu.swift            SelectionActionsMenu — Add to Collection / Add
                                   Tag / Share / Move to Folder over the effective
                                   selection (feat/multi-select)
    OutsideClickDeselect.swift     0×0 NSView + window leftMouseDown monitor that
                                   clears the selection on any click outside the
                                   grid's enclosingScrollView (feat/multi-select)
    PageScrollCatcher.swift        first-responder NSView giving the grid +
                                   Collections page native Page Up/Down (Fn+Arrow
                                   or real Page keys) via enclosingScrollView +
                                   PageScroll math (feat/page-scroll)
    ShareCollectionButton.swift    in-collection header menu — Save to… (NSSavePanel,
                                   Desktop) / Share (NSSharingServicePicker); builds
                                   an 11×14 paginated PDF (feat/collection-pdf-share)
    AspectRatioCache.swift         per-file aspect (h÷w) for layout: bulk DB
                                   width/height + ImageIO header fallback, off-main
    CollectionsPage.swift          dedicated Collections page (toolbar
                                   square.stack.3d.up): "Collections" header (back
                                   arrow + a far-right "+" New Collection button,
                                   trash-button sized) over a 4-up alphabetical
                                   card grid that resizes to fit, scrolls vertically
                                   (createManual → "Collection N")
    CollectionsRow.swift           in-collection header (back/rename/count) +
                                   the CollectionCard (right-click → Delete). Delete
                                   is DURABLE via setHidden — no user-facing Hide
                                   (2026-06-17); the all-collections cards moved to
                                   CollectionsPage 2026-06-13
    TagChipsRow.swift              tag chips; filter + management. A pure RENDERER
                                   of AppState.tagChipRows now (the model loads
                                   them via TagChipLoader — feat/next-10); keeps
                                   hover-count layout (ChipFlow) + rename/delete
                                   dialogs. Scope (collection members vs folder) is
                                   decided by AppState.tagSourceFiles
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
    SearchBar.swift                debounced FTS5 search. Native NSSearchField
                                   (system focus ring, clear button, accessibility;
                                   appearance follows mood) wrapped in
                                   NSViewRepresentable (feat/multi-select). Magnifier
                                   dropdown picks scope — All vs This Folder (default
                                   This Folder); drives AppState.searchAllFolders +
                                   runSearch (2026-06-17). InsetSearchFieldCell nudges
                                   the text ~4px right
    GridSelection.swift            pure selection math (single / Cmd-toggle /
                                   Shift-range → new set + anchor), unit-tested
                                   (feat/multi-select)
    PageScroll.swift               pure Page Up/Down math (newOriginY: overlap +
                                   clamp), unit-tested (feat/page-scroll)
    MasonryGeometry.swift          pure masonry packing (frames + height) from
                                   aspect ratios — feeds GridView's virtualization
                                   (replaced the old MasonryLayout: Layout, deleted
                                   2026-06-13 — a custom Layout can't virtualize).
                                   captionHeight param reserves a fixed per-tile
                                   caption strip for under-tile file names
                                   (feat/next-11)
  Export/
    CollectionPDFLayout.swift      pure paginated masonry pack for the collection
                                   PDF (no image split across pages), unit-tested;
                                   each tile reserves a captionHeight strip below
                                   the image for its filename (2026-06-17)
    CollectionPDFExporter.swift    ImageIO downsample (off-main) → CGPDFContext;
                                   CoreText 11×14 header (feat/collection-pdf-share)
                                   + a centered, ellipsis-truncated filename caption
                                   under each image (CTLineCreateTruncatedLine,
                                   2026-06-17)
  Effects/                         (was Fluid/, renamed 2026-06-17; water ripple
                                   removed 2026-06-13 and the burn-up delete
                                   SHADER removed too — NO Metal shaders remain)
    FadeOutModifier.swift          animatable staggered opacity fade for the
                                   delete sequence (replaced the BurnUp shader)
  Settings/
    AppSettings.swift              UserDefaults accessors for the automatic-
                                   organization opt-outs (autoTag /
                                   autoCollections, both default ON); read by
                                   AnalyzePipeline + CollectionsEngine. Plus
                                   showFileNames (default OFF; read by GridView —
                                   feat/next-11)
    SettingsView.swift             Preferences window (app menu → Settings…,
                                   ⌘,): the two auto-organization toggles
                                   (auto-tag new images / auto-organize into
                                   collections) + a "Grid" section with the
                                   "Show file names" toggle (feat/next-11).
                                   Other settings still live in the sidebar /
                                   toolbar / menus
  Muse.entitlements                app-sandbox + user-selected.read-write +
                                   bookmarks.app-scope + iCloud Documents +
                                   network.client (Sparkle update fetch ONLY —
                                   added 2026-06-15; no other network use) +
                                   mach-lookup temporary-exception for
                                   <bundleid>-spks/-spki (so the sandbox can run
                                   Sparkle's installer XPC — see SUEnableInstaller-
                                   LauncherService in Info.plist). DEBUG builds
                                   sign with Muse-Debug.entitlements (same keys
                                   MINUS iCloud) so dev-build churn can't claim/
                                   purge the production iCloud container — see the
                                   2026-06-16 iCloud isolation session log
  Muse-Debug.entitlements          Debug-only: Muse.entitlements without the three
                                   iCloud keys (Release/App Store keep iCloud)
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
  via `UNIQUE(file_id, parent_dir, label)` + branching in
  `Indexer.unionTags` and `AnalyzePipeline.analyzeOne`. This is what makes
  automatic re-analysis safe — it can never undo a user's tag edit.
- **Tags are per-file-LOCATION, not per content hash** (2026-06-17). A tag
  belongs to `(file_id, parent_dir)` — the same content in another folder
  is a different image with its own tags; deletes never leak across
  folders. Derive the folder key via `TagScope`. There is NO library-wide
  tag delete. Content-derived metadata (palette/caption/dims/intent) stays
  content-keyed by design (identical for identical pixels; auto-splits on
  edit). See the 2026-06-17 per-file-tags session log.
- **Analysis is automatic + incremental** — it runs after indexing for
  files whose `analyzed_hash` ≠ `content_hash` (new/changed only); never
  re-processes unchanged files. **Auto-tagging and auto-collections are
  opt-out** in Preferences (⌘, → `AppSettings`, both default ON): off → newly
  added folders stay viewable but aren't auto-processed, while existing data is
  untouched and the manual paths still work (menu-bar Regenerate Tags;
  hand-made collections via the Collections-page **+**). There's no prominent
  "Analyze" toolbar button — the automatic pass is the front door.
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
3. Toolbar (left → right): sidebar toggle · sort · sort-direction arrow
   (flips the active mode's order — newest↔oldest, A↔Z, …) · show-subfolders ·
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
- Test coverage: a real unit-test suite exists (`MuseTests`, ~36 files) —
  pure logic, schema migrations, and store/model behaviors (e.g. tag scoping +
  the `v7` migration, collection identity/membership, manual-collection naming,
  sort/selection/page-scroll math, palette/color/intent). UI views aren't
  unit-tested. Run with `xcodebuild -scheme Muse test`; keep it green.
- Current by-design behaviors (NOT bugs, NOT pending work — documented so a
  future session doesn't mistake them for defects):
  - iCloud Drive: dataless (not-yet-downloaded) files are skipped on
    index/hash until macOS downloads them (avoids empty-hash corruption).
  - iCloud sidecar hydration — two inherent behaviors: (1) **OCR full-text
    search is degraded on hydrate-only devices.** Sidecars don't carry OCR text
    (large; intentionally excluded), so a device that only hydrated a file
    (never ran Vision locally) matches FTS on basename + caption only, not OCR'd
    text. The file is marked analyzed, so it won't re-Vision to recover OCR.
    Intent IS carried, so intent collections are unaffected. (2) **Byte-identical
    content split across subfolders.** Sidecars live in a per-folder `.muse/`
    keyed by content hash; identical files in different subfolders of the iCloud
    zone only get a sidecar beside the copy that was analyzed, so the other copy
    won't hydrate on a fresh device until its own analyze pass runs.

## Working with this codebase

- Use the rewrite plan as the source of truth for "why does it work
  this way" questions.
- When in doubt about a product decision, the plan's locked Q-number
  table answers most of them.
- Keep commits scoped to a single phase or feature; the rewrite log
  is a useful reference and merging clean diffs preserves it.
