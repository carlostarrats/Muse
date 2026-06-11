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
  network access is blocked at the OS level.
- Data collection: **None**. Privacy nutrition label = "Data Not Collected".
- Min macOS: **14.6** (Vision/PDFKit/AVKit/FSEvents/FTS5 all work).
  Foundation Models chat panel is capability-gated to Apple Intelligence
  Macs (macOS 26+).
- Primary user persona: **generalist** — managing a Downloads folder,
  Documents, miscellaneous archives. Defaults bend to fast Quick Look
  + Open With; AI features available but not the front door.

## Plan documents

The full design lives in:

- `docs/superpowers/plans/file-viewer-rewrite.md` — the binding plan.
- `docs/superpowers/specs/2026-06-10-post-rewrite-polish-design.md` — the
  polish-pass spec (AI brain ✅, hero viewer ✅ shipped; spatial views and
  delights are phases 3–4, plans written per phase).
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

`feat/file-viewer-rewrite` was merged to `main` after Phase 8
finished — see the merge commit. The branch was kept around as an
audit trail of the per-phase progression.

## Architecture map (post-Phase-8)

```
Muse/Muse/
  App/
    MuseApp.swift                  entry point; starts fluidSim, runs ThumbnailCache LRU prune
    ContentView.swift              NavigationSplitView shell; toolbar wires every feature
  Models/
    AppState.swift                 @MainActor singleton — roots, active folder,
                                   current files, selected file, sort mode,
                                   search state, view mode, fluid + chat state
    AssetKind.swift                kind enum + extension/UTType detection
    FileNode.swift                 in-memory enumerated-file value type
    Root.swift                     security-scoped bookmark wrapper
  Filesystem/
    BookmarkStore.swift            UserDefaults-backed root bookmarks; lifecycle
                                   start/stop access for sandbox
    FolderTree.swift               lazy hierarchical tree + FolderReader
    FolderWatcher.swift            FSEvents-backed live watcher
    StarStore.swift                SQLite-backed starred folders
    ThumbnailCache.swift           QLThumbnailGenerator + 2-tier cache
                                   (NSCache + on-disk, LRU at 2GB cap)
  Database/
    Database.swift                 GRDB queue + migrations (v1 schema)
    Records.swift                  FileRow, PathRow, TagRow, etc.
    SearchService.swift            FTS5 + tag-label search with scope
    TagStore.swift                 manual/vision tag CRUD honoring Q32
  Indexing/
    HashService.swift              streaming SHA-256
    Indexer.swift                  identity reconciliation matrix (§4)
  Intelligence/
    Vision/
      VisionServices.swift         classify/OCR/faces/feature print/dom color
                                   + CaptionBuilder (Vision-derived, NOT LLM)
    Sort/
      SmartSorter.swift            8 sort modes; smart sorts pull FileRow data
    Dedup/
      DuplicateFinder.swift        byte-exact + visual + filename clusterers
                                   with smart-suggest only where signal is strong
    Chat/
      ChatService.swift            Foundation Models, capability-gated;
                                   context-prompted Q&A (no tool calls in v1)
    AnalyzePipeline.swift          orchestrates the Vision pipeline + writes
                                   to FileRow, tags, FTS5
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
    GridView.swift                 LazyVGrid, kind-aware icons, water shader
                                   layerEffect when fluidEnabled
    GlobeView.swift                Fibonacci-sphere image cluster (Phase 8)
    BreadcrumbView.swift           toolbar path breadcrumb
    OpenWithMenu.swift             NSWorkspace registered apps via LaunchServices
    ImageViewer.swift              fit/100% preview overlay
    QuickLookFallback.swift        QLPreviewView wrapper
    ViewerRouter.swift             AssetKind → viewer dispatch
    DetailPanelView.swift          right-side metadata + tag panel + Analyze
    DuplicatesView.swift           review pane with delete-to-Trash
    ChatPanelView.swift            collapsible chat panel
  Components/
    SearchBar.swift                debounced FTS5 search with scope toggle
    MasonryLayout.swift            (kept for future use)
  SceneKit/
    FibonacciSphere.swift          point distribution for GlobeView
  Fluid/
    FluidDistortion.metal          existing water-ripple shader (kept)
    FluidSim.swift                 CPU fluid sim (kept)
  Settings/
    SettingsView.swift             placeholder; real Preferences pane is
                                   future work
  Muse.entitlements                app-sandbox + user-selected.read-write +
                                   bookmarks.app-scope (no network entitlement)
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
  `AnalyzePipeline.analyzeOne`.
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

All Q1–Q33 from the plan are locked in. Future product decisions
should be recorded in `docs/superpowers/plans/file-viewer-rewrite.md`
(or a sibling plan doc) before implementation.

## How to run

1. Open `Muse/Muse.xcodeproj` in Xcode 16+.
2. Build & run (Cmd+R). The app starts on a clean shell — click
   "Add Folder" in the sidebar to point Muse at any folder on disk.
3. Toolbar buttons (left → right): breadcrumb · search · grid/globe ·
   sort · subfolders · analyze · find duplicates · details · chat
   (when AI-capable) · water effect.
4. Database lives at `~/Library/Application Support/Muse/muse.sqlite`.
   Wipe by deleting that file; the app rebuilds the schema on next
   launch.
5. ThumbnailCache: `~/Library/Application Support/Muse/ThumbnailCache/`.
   Capped at 2GB, LRU-evicted on launch.

## Status as of merge to main

- Branch state: `main` is now at the merged tip; `dev` is preserved at
  the pre-rewrite water-toggle commit (older); `feat/file-viewer-rewrite`
  is the source-of-truth branch for the rewrite progression.
- Test coverage: none. (Test suites are a separate workstream.)
- Known soft spots:
  - Code syntax highlighting (renders as plain monospaced for now).
  - iCloud Drive UI (download-state badges deferred).
  - Saved smart searches (schema exists; UI is post-v1).
  - Archive browse-without-extracting (uses Quick Look).
  - Onboarding flow (separate design pass needed).
  - Settings/Preferences pane (placeholder only).

## Working with this codebase

- Use the rewrite plan as the source of truth for "why does it work
  this way" questions.
- When in doubt about a product decision, the plan's locked Q-number
  table answers most of them.
- Keep commits scoped to a single phase or feature; the rewrite log
  is a useful reference and merging clean diffs preserves it.
