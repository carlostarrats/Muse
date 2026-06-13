# Muse — Claude project notes

This file is loaded into Claude's context when working in this repo.
It documents the project's identity, current state, and conventions
so a fresh Claude session can pick up productively.

## Project identity

Muse is a **filesystem-native universal file viewer + AI-organized
asset library** for macOS, in the spirit of Adobe Bridge but
local-first, Apple-Intelligence-native, and free forever.

- Distribution: **Mac App Store**, sandboxed
- Pricing: **Free**, no IAPs, no subscriptions, no ads
- Network policy: **Zero**. No analytics, no telemetry, no remote
  fetches. The sandbox doesn't include `network.client` — accidental
  network access is blocked at the OS level. iCloud Drive *document*
  sync (used for the optional single "Muse" iCloud folder) is mediated
  by the OS sync daemon and adds only the iCloud Documents entitlement —
  **not** `network.client`. The app still makes zero network calls and
  the developer receives no data, so the "Data Not Collected" privacy
  label is unchanged.
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
- **Still pending Xcode/user steps** — the iCloud Documents + App Groups
  capabilities and code signing (Task 6), the share-extension target
  (Task 11), and interactive runtime verification of the sync round-trip +
  share sheet are done in Xcode by the user (they require the Apple Developer
  account GUI). The Swift code for everything else is landed and build-verified.
- **Pre-req fix** — removed orphaned `SimilarityLayoutTests`/`CloudMathTests`
  (referenced source deleted in the perf session) that were breaking the
  `MuseTests` target.

## Architecture map (current — see the 2026-06-12 session log for deltas)

```
Muse/Muse/
  MuseApp.swift                    entry point; ThumbnailCache LRU prune +
                                   180-day Housekeeping prune + IntentBackfill
                                   on launch
  ContentView.swift                NavigationSplitView shell; floating tag
                                   chips; toolbar; menu-bar Tags/Collections
  Models/
    AppState.swift                 @MainActor singleton — roots, active folder,
                                   current files, selected file, sort mode,
                                   search, view mode, collection + tag filters,
                                   mood, fluid state
    AssetKind.swift                kind enum + extension/UTType detection
    FileNode.swift                 in-memory enumerated-file value type
    Root.swift                     security-scoped bookmark wrapper
    DeleteCoordinator.swift        burn-delete state machine: trash + undo toast
    Mood.swift                     Light / Dark / Auto (day↔night) / Custom HSB
                                   (AutoTint retired)
  Filesystem/
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
    SidebarView.swift              multi-root OutlineGroup tree + starred section
    GridView.swift                 VIRTUALIZED masonry grid — precomputes tile
                                   frames (MasonryGeometry from AspectRatioCache)
                                   and renders only viewport tiles (+overscan);
                                   column-count slider; water shader when fluidEnabled.
                                   The ONLY view mode (cloud/galaxy retired 2026-06-13)
    AspectRatioCache.swift         per-file aspect (h÷w) for layout: bulk DB
                                   width/height + ImageIO header fallback, off-main
    CollectionsRow.swift           Cosmos-style cards + in-collection editable header
    TagChipsRow.swift              folder-scoped tag chips; filter + management
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
    SearchBar.swift                debounced FTS5 search, scoped to sidebar folder
    MasonryGeometry.swift          pure masonry packing (frames + height) from
                                   aspect ratios — feeds GridView's virtualization
                                   (replaced the old MasonryLayout: Layout, deleted
                                   2026-06-13 — a custom Layout can't virtualize)
  Fluid/
    FluidDistortion.metal          existing water-ripple shader (kept)
    FluidSim.swift                 CPU fluid sim (kept)
    BurnUp.metal                   burn-up delete shader (chars edges-in + embers)
    BurnUpModifier.swift           animatable layerEffect wrapper (chains after water)
  Settings/
    SettingsView.swift             placeholder; real Preferences pane is
                                   future work
  Muse.entitlements                app-sandbox + user-selected.read-write +
                                   bookmarks.app-scope + iCloud Documents
                                   (no network entitlement)
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
   search (center) · clear-collection (when filtered) · background mood ·
   water effect · ⓘ About. (The grid/cloud/galaxy view picker was removed
   2026-06-13 — grid is the only view.) Find Duplicates lives in the File
   menu; Pin/Unpin Folder and Remove Folder live in the Edit menu; analysis
   runs automatically.
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

## Working with this codebase

- Use the rewrite plan as the source of truth for "why does it work
  this way" questions.
- When in doubt about a product decision, the plan's locked Q-number
  table answers most of them.
- Keep commits scoped to a single phase or feature; the rewrite log
  is a useful reference and merging clean diffs preserves it.
