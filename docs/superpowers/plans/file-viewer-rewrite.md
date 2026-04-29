# Muse — Filesystem-Native Rewrite Plan

**Branch:** `feat/file-viewer-rewrite`
**Date drafted:** 2026-04-28
**Status:** approved direction, not yet implemented

---

## 1. What's changing

Muse pivots from an **import-based image inspiration vault** to a **filesystem-native universal file viewer + AI-organized asset library**, in the spirit of Adobe Bridge.

### Old identity (what we're leaving behind)
- Import images into a Muse-managed library at `~/Library/Application Support/Muse/`
- Collection-based hierarchy
- Image-only, with 3D Universe / Globe / Folder views as the primary visualizations

### New identity
- Point Muse at any folder on disk; that's the "Muse root" — no lock-in, no dedicated Muse folder
- Sidebar is a real filesystem tree (Adobe Bridge style)
- View any kind of file natively: images, PDFs, text, markdown, RAW, PSD preview, SVG, video, audio, code, Office docs, 3D, fonts, archives
- Smart on-device AI features (auto-tag, dedup, semantic sort) running on Apple Vision + Foundation Models
- Exposed to external AI agents via MCP server (Claude Desktop, Perplexity Comet, etc.)
- Optional local-only chat panel for natural-language search

### Tagline
> A local-first, AI-native universal file viewer for creatives. Browse any folder. Tag anything. Find duplicates. Talk to your library.

---

## 2. Locked decisions

| # | Topic | Decision |
|---|---|---|
| Q1 | Sidebar source | Real filesystem tree. Folders are starable. Any folder is a valid root. No dedicated Muse folder. |
| Q2 | Folder click behavior | Filter grid to that folder only (Adobe Bridge style). "Show subfolders" toggle for recursive view. |
| Q3 | Disk sync | Live — **FSEvents** (kernel-coalesced, persistent across launches) on the active folder, with optional recursive mode. Same API every serious macOS file manager uses. |
| Q4/Q5 | Image editing | **None inside Muse.** Right-click → "Open With…" lists every macOS app registered for the file type via `LaunchServices`. |
| Q6 | Text/Markdown | Read-only with selectable text, Markdown rendered. Editing goes to TextEdit/Notes/etc. via Open With. |
| Q7 | PDF | View-only — scroll, zoom, search, select/copy text. Annotations via Preview/Acrobat. |
| Q8 | AI scope | Three layers: (a) on-device AI inside Muse, (b) MCP server for external agents, (c) optional local chat panel. |
| Q9 | Chat panel runtime | Apple Foundation Models on Apple Intelligence-capable Macs **only**. No fallback. If your Mac can't run Foundation Models, the chat panel is hidden. (Earlier MLX-bundled-model fallback dropped — likely to disappoint, defers cleanly to a future release if demand emerges.) Strict on-device. |
| Q10 | Auto-tagging | **On-demand only** — user clicks "Analyze" on a file/folder. No background work. |
| Q11 | Duplicate detection | **On-demand only** — user clicks "Find Duplicates" on a scope. |
| Q12 | Dedup suggestions | Smart suggest only where signal is strong: byte-exact dupes (rock solid), visual dupes with >10% resolution gap (reliable). Visual-similar at same resolution / filename-only dupes: no suggestion. **Delete always = move to Trash.** Never `unlink`. |
| Q13 | MCP server scope | Muse-internal organization only. Read disk, but writes only touch Muse's database (tags, stars, collections, smart searches). **No file moves/renames/deletes via MCP.** |
| Q14 | Smart sort | Dominant color, detected object/scene, face count, has-text-or-not, plus visual semantic clustering via Apple's image feature embeddings. |
| Q15 | Min macOS | **macOS 14**. Vision, PDFKit, AVKit, FSEvents, FTS5 — all work. Foundation Models (chat panel) is capability-gated within macOS 14+: requires Apple Intelligence-enabled Mac on macOS 26+. Lower floor widens v1 audience at zero cost to other features. |
| Q16 | File types | Universal viewer — see §4 for the full table. Anything unsupported falls back to Quick Look. |
| Q17 | Scale target | Large (100k+ files). Architecture decisions (FTS5, paged queries, vector index, lazy folder load) all assume large libraries. Small libraries pay no penalty. |
| Q18 | File identity | Hybrid — primary key is content SHA-256, with path tracking. Move a file in Finder → tags follow (path-based identity). Edit content → tags stay attached to the same path, hash updated. See §4 reconciliation matrix for all cases. |
| Q19 | View modes | **Keep:** Grid (default), Globe (reworked for current-folder content). **Drop:** Universe, Folder-3D. |
| Q20 | Sidebar contents | Just the folder tree. Tags / starred / saved searches live elsewhere in the UI (TBD). |
| Q21 | Search scope | Default = current folder. Toggle in search bar for "search everywhere" (entire indexed library). |
| Q22 | DB migration | Wipe & start fresh. Existing user-data file at `~/Library/Application Support/Muse/` left untouched on disk for now (new app simply doesn't read it). |
| Q23 | Distribution | **Mac App Store**, sandboxed, free forever. Apple Developer account already in place. Auto-updates via App Store. |
| Q24 | Primary user persona | **Generalist** — managing a Downloads folder, Documents, miscellaneous archives. Defaults bend toward fast Quick Look + Open With; AI features available but not the front door. |
| Q25 | Globe & water shader | **Keep both. Polish later.** Globe view reworked for current-folder content. Water shader stays as alt visualization for image folders. |
| Q23a | Pricing | **Free forever.** No purchase, no subscriptions, no in-app purchases, no ads. Privacy nutrition label: **Data Not Collected.** |
| Q23a' | Network policy | **Zero network calls, ever.** No analytics, no telemetry, no update pings, no crash reporting that leaves the device, no auto-suggest fetches, no remote config, no fonts loaded from the web, no SVG resources fetched. The app does not request the network entitlement. Apple's built-in crash reports (Xcode → App Store Connect) are the only failure-signal channel — they're routed by Apple, not by Muse. |
| Q23b | MCP (consequence of App Store) | **Dropped from v1.** Sandbox blocks Unix-socket IPC to external agents (Claude Desktop, Comet, Cursor). Replaced by **App Intents** for Shortcuts/Siri/Spotlight automation. If MCP becomes load-bearing later, it requires a direct-distribution build (Q23 reopens). |
| Q23c | iCloud Drive support | **Yes — best practice.** A root can be `~/Library/Mobile Documents/com~apple~CloudDocs/…`. Honor `NSURLUbiquitousItemDownloadingStatusKey`; auto-trigger downloads on file access; show "downloading from iCloud" state in grid for `NSURLUbiquitousItemIsDownloadingKey`. |
| Q23d | Sandbox entitlements | `com.apple.security.app-sandbox`, `com.apple.security.files.user-selected.read-only`, `com.apple.security.files.bookmarks.app-scope`. **Read-only on user files in v1.** Read-write requested in Phase 4 when dedup-to-Trash ships, with rationale in App Review notes. **No `com.apple.security.network.client` entitlement** — the absence is enforcement; sandbox blocks any accidental network access at the OS level. |
| Q23e | Onboarding flow | **TBD — design separately before Phase 0.5 implementation.** Generalist users need a clear first-folder-pick moment + brief explanation of what Muse does. Flow spec lives in a sibling plan doc. |
| Q26 | Multi-root | **Multi-root, Finder-favorites style.** Sidebar shows roots as top-level groups; each independently navigable; starred folders pinned across all roots in their own section above. |
| Q27 | Identity reconciliation | Byte-identical files at different paths = **one** `files` row with multiple `paths` children. **Tags shared across all paths of the same content.** Deliberate; documented for users. See §4 for the full decision matrix. |
| Q28 | Captions | Captions come from **Vision**, not the LLM. Object/scene labels + OCR text + dominant color, concatenated and stored on `files.caption` for FTS indexing. (Foundation Models was wrong API for this.) |
| Q29 | FileNode lifecycle | Three stages, **derived not stored**: `enumerated` (path row, `file_id` NULL) → `seen` (hashed, linked to a `files` row, no Vision yet) → `indexed` (feature print present). Grid renders from stage 1. See §3.1. |
| Q30 | Path resurrection | Dead paths are kept; uniqueness is `UNIQUE(absolute_path) WHERE is_alive = 1`. Reviving a known dead path flips `is_alive = 1` and reuses the row + tags. |
| Q31 | MCP transport | External `muse-mcp` CLI binary spawned by the agent; talks to Muse.app via Unix domain socket. Long-running tools return `jobId` + use MCP progress notifications. Binary content (thumbnails) via MCP resources, not base64 in JSON-RPC. |
| Q32 | Tag uniqueness | `UNIQUE(file_id, label)`. Source enum (`manual`, `vision`); manual beats vision on conflict. |
| Q33 | Indexer policies | Symlinks: follow once with cycle detection. Bundles (`.app`, `.photoslibrary`, etc.): treat opaque, don't descend. Hidden files (`.DS_Store`, dotfiles, `__MACOSX`): skip by default with a "show hidden" preference. |

### Cross-cutting principle
**Muse views; specialist apps edit.** Editing of any kind (image, PDF, text, video) is delegated to whatever app the user already trusts via "Open With…" rather than reimplemented inside Muse.

---

## 3. Architecture overview

```
Muse/
  App/
    MuseApp.swift                 (entry point)
    AppState.swift                (top-level @ObservableObject)
    Theme/                        (colors, typography, materials)

  Models/
    FileNode.swift                (filesystem entry — path, hash, kind, size, dates)
    AssetKind.swift               (enum: image, raw, pdf, text, md, video, audio, code, office, font, archive, model3d, unknown)
    Tag.swift                     (label, source: manual/auto, confidence)
    Star.swift                    (starred folder pointer)
    SmartSearch.swift             (saved query)
    DuplicateGroup.swift          (cluster of dupes with reason)

  Filesystem/
    FolderTree.swift              (hierarchical tree built lazily from disk)
    FolderWatcher.swift           (FSEvents-backed live watcher; supports recursive mode)
    ThumbnailCache.swift          (QLThumbnailGenerator + on-disk cache, keyed by file_id; LRU eviction with 2GB default cap, user-configurable in Preferences)
    BookmarkStore.swift           (security-scoped bookmarks for sandbox-safe folder access)
    PathResolver.swift            (path ↔ hash reconciliation)

  Indexing/
    Indexer.swift                 (background queue; walks folder, hashes, indexes)
    HashService.swift             (SHA-256 byte hash + perceptual hash for visual)
    FeaturePrintService.swift     (VNGenerateImageFeaturePrintRequest cache)
    FTSService.swift              (SQLite FTS5 reads/writes)

  Database/
    Schema.swift                  (CREATE TABLE statements)
    Repository.swift              (typed query layer)
    Migrations.swift              (versioned schema changes)
    VectorIndex.swift             (cosine similarity over feature prints)

  Viewers/
    ViewerRouter.swift            (AssetKind → SwiftUI viewer)
    ImageViewer.swift             (NSImage + zoom/fit/100% — current overlay reused)
    RAWViewer.swift               (ImageIO RAW pipeline)
    PSDViewer.swift               (ImageIO flat composite)
    SVGViewer.swift               (WKWebView)
    PDFViewer.swift               (PDFKit, view-only)
    TextViewer.swift              (NSTextView, selectable, read-only)
    MarkdownViewer.swift          (AttributedString markdown render)
    CodeViewer.swift              (TreeSitter or Highlightr syntax highlight)
    OfficeViewer.swift            (NSAttributedString for .rtf only; .docx/.doc/.pages → Quick Look)
    VideoPlayer.swift             (AVKit)
    AudioPlayer.swift             (AVKit + waveform)
    ModelViewer.swift             (SceneKit/RealityKit USDZ/OBJ)
    FontViewer.swift              (CTFont glyph table + sample text)
    ArchiveBrowser.swift          (read-only zip/tar.gz contents)
    QuickLookFallback.swift       (QLPreviewController for unknown types)

  Views/
    GridView.swift                (reworked — driven by FileNode + AssetKind)
    GlobeView.swift               (reworked — current folder's images on Fibonacci sphere)
    SidebarView.swift             (folder tree, multi-root, starred section)
    ToolbarView.swift             (path breadcrumb, search, view-mode toggle, AI buttons)
    SearchBar.swift               (current-folder vs everywhere scope toggle)
    DetailPanel.swift             (selected file metadata, tags, actions)
    DuplicatesPane.swift          (review groups, suggestions, delete-to-trash)
    TagPanel.swift                (manual + auto tag editor)
    ChatPanel.swift               (optional local-LLM chat; hideable)

  Intelligence/
    Vision/
      ClassifyService.swift       (VNClassifyImageRequest → tags)
      OCRService.swift            (VNRecognizeTextRequest → searchable text)
      FaceService.swift           (VNDetectFaceRectanglesRequest → counts/locations)
      DominantColorService.swift  (CIAreaAverage → palette)
      CaptionBuilder.swift        (concatenates Vision outputs into a single searchable caption string)
    Chat/
      FoundationModelService.swift (Apple Foundation Models — chat panel only, no captions)
    Dedup/
      DuplicateFinder.swift       (orchestrator)
      ByteExactClusterer.swift    (SHA-256 grouping)
      PerceptualClusterer.swift   (feature-print + cosine threshold)
      FilenameClusterer.swift     (basename grouping with content disambiguation)
    Sort/
      SmartSorter.swift           (color, object, face, has-text, semantic-cluster modes)

  Agents/
    AppIntents/
      OpenFolderIntent.swift      (open a specific folder by path)
      FindDuplicatesIntent.swift  (run dedup scan in current folder)
      AnalyzeFolderIntent.swift   (run Vision pipeline on a folder)
      SearchLibraryIntent.swift   (FTS5 over indexed library, returns FileSummary[])
      TagFileIntent.swift         (add/remove tag; runs only while Muse is foregrounded)
      AppShortcutsProvider.swift  (registers all intents with the system)

  Editing/                        (REMOVED — see §6 — kept slot for future)

  Fluid/                          (kept — water shader is alt grid visualization)
    FluidSim.swift
    FluidDistortion.metal

  Settings/
    PreferencesView.swift         (roots, AI options, dedup thresholds, MCP toggle)
    Roots.swift                   (multi-root manager)
```

### 3.1 FileNode lifecycle (pre-hash → post-hash → indexed)

The grid must render before files are hashed — hashing 100k files takes minutes, not seconds. So `FileNode` has three stages, and capabilities light up progressively:

| Stage | What's known | DB state | What works in UI | What doesn't |
|---|---|---|---|---|
| **enumerated** | Path, basename, size, mtime, kind (by extension) | `paths` row only; no `files` row yet | Grid render, sort by name/date/size, Open With, Quick Look preview, double-click to open file | Tagging (no `file_id`), find-similar, dedup, smart sort, FTS search hits |
| **seen** | + content hash, deduped to a `files` row | `files` row + linked `paths` row | Above + tagging, byte-exact dedup, identity-aware operations | Vision-derived tags, captions, feature-print similarity, semantic clustering |
| **indexed** | + Vision outputs (tags, OCR, faces, dominant color, feature print, caption) | `files.caption`, `tags`, `files.feature_print` populated | Everything | — |

**Stage transitions** are async and idempotent:
- `enumerated → seen`: background queue, hashes in batches; folder open shows a quiet "indexing N files…" indicator.
- `seen → indexed`: only on user action (Q10 — Analyze button). Never automatic.

**UI rules** that fall out of this:
- Right-click → Open With… works at *all* stages (we have a path).
- "Tag this file" requires stage `seen`. If user tags a stage-`enumerated` file, the action is queued and applied as soon as hashing completes (sub-second in practice).
- Selecting a stage-`enumerated` file works fine; the detail panel shows path/size/kind without tags or caption.
- "Find duplicates" / "Find similar" / "Sort by visual cluster" disable themselves with a tooltip ("waiting for indexing") if the scope contains stage-`enumerated` files.

### Key external dependencies
- **GRDB.swift** — already used; keep for SQLite layer (schema is new).
- **SQLite FTS5** — bundled in macOS SQLite, just needs a `CREATE VIRTUAL TABLE` migration.
- **TreeSitter or Highlightr** — code syntax highlighting. (Pick during impl.)
- **MCP Swift SDK** — pick the Anthropic-blessed Swift SDK if available, else implement the JSON-RPC stdio protocol directly (it's small).

### Frameworks (no external deps)
- **PDFKit** — PDF viewer
- **Vision** — classify, OCR, faces, feature prints
- **AVKit** — video/audio
- **SceneKit/RealityKit** — 3D models, globe rework
- **Quick Look (`QLPreviewController`)** — universal fallback
- **Foundation Models** (macOS 26+) — chat panel
- **AppIntents** — Shortcuts/Siri
- **NSWorkspace** — Open With… resolution and execution

### Hard architectural invariant: no network
- The app's `Info.plist` does **not** declare `NSAppTransportSecurity` exceptions.
- The sandbox entitlements file does **not** include `com.apple.security.network.client` or `com.apple.security.network.server`.
- No `URLSession`, `NSURLConnection`, `URLProtocol`, `Network.framework`, raw socket, or `Process` invocation that performs HTTP. Any of these in a code review = automatic reject.
- Markdown rendering ignores remote `<img>` tags rather than fetching. SVG viewer's WKWebView gets a `WKWebpagePreferences` policy that blocks all network loads.
- Any third-party Swift package added later goes through the same audit: zero network surface area.

---

## 4. Data model

### `files`
| column | type | notes |
|---|---|---|
| `id` | TEXT PK | UUID |
| `content_hash` | TEXT UNIQUE | SHA-256. Set when stage advances to `seen`. |
| `kind` | TEXT | AssetKind raw value |
| `size_bytes` | INTEGER | |
| `width` | INTEGER NULL | images/video |
| `height` | INTEGER NULL | |
| `duration_seconds` | REAL NULL | video/audio |
| `created_at` | INTEGER | filesystem birth time |
| `modified_at` | INTEGER | filesystem mtime |
| `last_seen_at` | INTEGER | last time indexer saw this file on disk |
| `caption` | TEXT NULL | concatenated Vision outputs (set at stage `indexed`) |
| `dominant_color` | TEXT NULL | hex |
| `feature_print` | BLOB NULL | VNFeaturePrintObservation data |

**Lifecycle stage is derived, not stored.** A file's stage is computed from its rows:
- `paths.file_id IS NULL` → `enumerated`
- `paths.file_id IS NOT NULL AND files.feature_print IS NULL` → `seen`
- `files.feature_print IS NOT NULL` → `indexed`

Storing the stage explicitly was tempting but unrepresentable: at `enumerated`, no `files` row exists yet, so there's nowhere to put the column.

### `paths`
| column | type | notes |
|---|---|---|
| `id` | TEXT PK | |
| `file_id` | TEXT FK → files.id NULL | NULL while stage = `enumerated` (no hash yet to attach to a `files` row) |
| `absolute_path` | TEXT | |
| `bookmark_data` | BLOB | security-scoped bookmark for sandbox |
| `is_alive` | INTEGER | 1 if still on disk |

**Indexes / uniqueness:**
- `UNIQUE INDEX paths_alive_unique ON paths(absolute_path) WHERE is_alive = 1` — partial unique index. Allows path resurrection: a dead row can stay around with the same `absolute_path` while a new alive row exists, but never two alive rows for the same path.
- `INDEX paths_file_id_idx ON paths(file_id)` — hot query: "all alive paths for file_id" runs constantly (grid selection, dedup grouping, copy-count badges).

A file can have multiple paths (hardlinks, copies). Removing the last alive path is what makes a file "gone." Dead rows are pruned after 30 days unless their `files` row has tags or a feature print.

### `tags`
| column | type | notes |
|---|---|---|
| `id` | TEXT PK | |
| `file_id` | TEXT FK | |
| `label` | TEXT | |
| `source` | TEXT | `manual` or `vision` |
| `confidence` | REAL NULL | 0..1 for vision tags |

**Indexes / uniqueness:**
- `UNIQUE(file_id, label)` — one row per `(file, label)` pair. **Manual beats vision on conflict** (manual writes overwrite vision rows; vision writes ignore existing manual rows).

### `roots`
| column | type | notes |
|---|---|---|
| `id` | TEXT PK | |
| `bookmark_data` | BLOB | security-scoped bookmark |
| `display_name` | TEXT | |
| `added_at` | INTEGER | |
| `is_starred` | INTEGER | starred folders pinned |

### `smart_searches`
| column | type | notes |
|---|---|---|
| `id` | TEXT PK | |
| `name` | TEXT | |
| `query_json` | TEXT | encoded SmartSearch struct |

### `duplicate_groups` (transient — populated on-demand)
| column | type | notes |
|---|---|---|
| `id` | TEXT PK | |
| `reason` | TEXT | "byte_exact", "visual", "filename" |
| `created_at` | INTEGER | |

### `duplicate_members`
| column | type | notes |
|---|---|---|
| `group_id` | TEXT FK | |
| `file_id` | TEXT FK | |
| `is_suggested_keeper` | INTEGER | 1 if smart-suggested to keep |

### FTS5 virtual tables
- `files_fts(file_id UNINDEXED, basename, ocr_text, caption)` — keyed by immutable `files.id`, not the mutable `content_hash`. Avoids rewriting FTS rows on every edit-in-place.

### Vector index — explicit scaling rules
- Feature prints stored as `BLOB` on `files.feature_print`.
- **Visual dedup and "find similar" default to current-folder scope.** "Search everywhere" exists but is opt-in with a "this may take a while" disclaimer.
- Even at folder scope, candidates are pre-filtered by **resolution bucket** (within ±10%) and **dominant-color hash** (8-bit perceptual hash) *before* computing cosine. This typically prunes the candidate set 50–500×.
- Brute-force cosine over the surviving candidates only. At realistic folder sizes this stays interactive (<200ms).
- Library-wide scans run on a background queue and present a progress UI. No interactive guarantees there.
- HNSW / LSH not implemented in v1. Trigger to add: a real user with a 100k+ "everywhere" workflow that's painful in practice. Until then, scope-by-default is the cheaper answer.

### Identity reconciliation matrix

**Anchor point:** every row below describes the action taken **at the moment hashing completes for a previously-enumerated path** (or the equivalent moment when re-hashing detects a content change). Path enumeration alone (the `enumerated` stage) just creates a `paths` row with `file_id = NULL` — no reconciliation happens until there's a hash to reconcile.

| Path state | Hash state | Interpretation | Action |
|---|---|---|---|
| Newly-enumerated path | Hash unknown to DB | Brand new file | Create `files` row; set `paths.file_id` to it. Both alive. |
| Newly-enumerated path | Hash matches an existing alive `files` row | Copy / hardlink of known content | Set `paths.file_id` to the existing row. **Tags are shared across all alive paths.** |
| Known alive path | Same hash as before | Unchanged file | Touch `last_seen_at` on `files`. |
| Known alive path | New hash, no other `files` row has it | Edited in place | Update `files.content_hash` on the row this path points to. **Tags remain attached.** |
| Known alive path | New hash matches a *different* existing `files` row | Edited to be byte-identical to another known file (rare but real — e.g. paste, copy-merge) | Re-link `paths.file_id` to the matching row. **Tags from the previous row are unioned into the matching row** following Q32's rule (manual beats vision on label conflict; otherwise both kept). If the previous `files` row now has zero alive paths, mark its dead paths orphaned and prune the row after the 30-day grace window. Union prevents quiet data loss when the orphaned row's only alive path was this one. |
| Known alive path absent on disk | n/a | File deleted or moved away | Mark `paths.is_alive = 0`. If no other alive paths point to this `files` row, the file is "gone" but row + tags persist 30 days. |
| Newly-enumerated path identical to a known **dead** path | Hash matches the dead row's `files` | Path-resurrection (drive remounted, file restored from backup) | Flip `is_alive = 1` on the dead row, reuse `files` row + tags. |
| Newly-enumerated path identical to a known **dead** path | Hash differs from the dead row's `files` | Path was reused with new content | Create a fresh `files` row, link a new alive `paths` row, leave the dead row in place to be pruned. |
| Lightroom-style export to a new path | New hash | Derivative of a known original | Treated as a brand-new file. **Tags do NOT auto-attach.** No special detection — we don't track "this came from that," and we don't pretend to. |

**Consequence to know:** if you copy `logo.png` into three folders, it's one row with three paths. Tagging "blue" tags all three. Deleting one path doesn't remove the tag. This is deliberate — matches Lightroom's "virtual copy" model and avoids the "same image, different tag set in each copy" footgun.

---

## 5. File-type viewer routing

| AssetKind | Viewer | Notes |
|---|---|---|
| `image` (jpg, png, heic, webp, gif, tiff, bmp, ico) | `ImageViewer` | reuses current overlay logic |
| `raw` (cr2, cr3, nef, arw, dng, orf, rw2…) | `RAWViewer` | ImageIO embedded preview, full decode on demand |
| `psd` | `PSDViewer` | flat composite via ImageIO; no layer editing |
| `svg` | `SVGViewer` | WKWebView for fidelity |
| `pdf` | `PDFViewer` | PDFKit, view-only, search, select |
| `text` (.txt, .log, .csv, etc.) | `TextViewer` | NSTextView, selectable, read-only |
| `markdown` (.md, .markdown) | `MarkdownViewer` | rendered + selectable |
| `code` (.swift, .ts, .js, .py, .go, .rs, .cpp, .h, .json, .yaml, .toml, .html, .css…) | `CodeViewer` | syntax highlighted |
| `office` (.rtf) | `OfficeViewer` | NSAttributedString — handles `.rtf` cleanly |
| `office` (.docx, .doc, .pages) | Quick Look fallback | NSAttributedString's `.docx` rendering is too lossy (tables, images, comments). Quick Look hands off to its native renderer. |
| `video` (mp4, mov, m4v, mkv*, webm*) | `VideoPlayer` | AVKit; mkv/webm via QL fallback |
| `audio` (mp3, wav, aac, m4a, flac) | `AudioPlayer` | AVKit + waveform |
| `model3d` (.usdz, .obj, .stl) | `ModelViewer` | SceneKit/RealityKit |
| `font` (.ttf, .otf, .woff, .woff2) | `FontViewer` | glyph grid + sample paragraph |
| `archive` (.zip, .tar, .tar.gz) | `ArchiveBrowser` | browse without extracting |
| anything else | `QuickLookFallback` | macOS does its best |

Asset detection is by extension first, content sniffing (magic bytes / UTType) as a tiebreak.

---

## 6. AI integration

### On-device features (run only when user clicks)

- **"Analyze" on a file/folder** triggers the Vision pipeline:
  - `VNClassifyImageRequest` → tags with confidence
  - `VNRecognizeTextRequest` → OCR text → tags + FTS index
  - `VNDetectFaceRectanglesRequest` → face count tag
  - `VNGenerateImageFeaturePrintRequest` → embedding for clustering/dedup
  - Dominant color extraction via `CIAreaAverage`
  - **Caption** (`files.caption`) is composed by `CaptionBuilder` from the above signals — top scene/object labels + OCR-text snippet + dominant color name. Plain text, indexed in FTS5. **Not produced by Foundation Models.**

- **Vision partial-failure policy.** Pipeline requests run independently. The file advances to stage `indexed` if `VNGenerateImageFeaturePrintRequest` succeeds, even if classify/OCR/face/color fail (each is logged with the underlying error). A subsequent "Analyze" call is a clean retry — succeeded steps are skipped (already populated), failed steps are re-attempted. If feature print itself fails, the file stays at stage `seen` and the user is notified once per Analyze run.

- **Indexer priority.** Hashing the **active folder** (the one currently visible in the grid) runs on a high-priority queue with a small worker pool. Every other root or subfolder is best-effort on a single low-priority background worker. When the user navigates to a different folder, the active queue is drained first before the new folder takes priority. Without this, opening a freshly-added 100k root would starve everything else.

- **Job persistence.** `JobStore` is in-memory only in v1. Quitting Muse cancels in-flight scans (`runDuplicateScan`, `runAnalyze`). Persisting jobs to SQLite + resuming on launch is a post-v1 feature, gated on real demand.

- **"Find Duplicates"** runs three clusterers in parallel and merges results into `DuplicateGroup`s with `reason` annotated.

- **Sort dropdown** options, in the order the generalist persona expects:
  - **Date Modified (descending)** — default; what 90% of users want when triaging Downloads
  - Date Created
  - Name (A-Z)
  - Size (largest first)
  - Kind (group by AssetKind)
  - *Smart Sort group:*
    - Dominant color (HSV hue)
    - Object/scene category (top-confidence tag)
    - Face count (descending)
    - Has-text (OCR presence)
    - Visual cluster (k-means/DBSCAN over feature prints)

- **Default dedup priority** (generalist):
  1. Byte-exact (rock-solid, primary)
  2. Filename + size (close-second, fast)
  3. Visual similarity (opt-in, slowest)

### MCP server — *cut from v1, see Q23b*

The originally-spec'd MCP server (Unix-socket bridge → external `muse-mcp` CLI) is incompatible with Mac App Store sandbox: sandboxed apps cannot accept connections from arbitrary external processes via Unix sockets in the user home. This was an explicit trade made when distribution was locked to App Store (Q23). External-agent integration (Claude Desktop, Comet, Cursor) is **not in v1**. A direct-distribution build with MCP remains a future option but requires reopening Q23.

### App Intents — primary automation surface

App Intents is the App Store-blessed automation path. Exposes Muse to **Shortcuts**, **Siri**, **Spotlight**, **Focus Filters**, and any system-level invocation point Apple opens up. Intents shipped:

- `OpenFolderIntent(path: URL)` — navigate Muse to a specific folder; runs in background or foreground.
- `FindDuplicatesIntent(scope: FolderRef)` — kicks off dedup scan; returns once cached results land.
- `AnalyzeFolderIntent(scope: FolderRef)` — runs the Vision pipeline.
- `SearchLibraryIntent(query: String, scope: SearchScope)` → `[FileSummaryEntity]` — FTS5 search.
- `TagFileIntent(file: FileEntity, label: String, action: add|remove)` — runs only while Muse is foregrounded (App Store rule for write actions on user content).
- `StarFolderIntent(path: URL)` / `UnstarFolderIntent(path: URL)` — manage starred folders.

`AppShortcutsProvider` registers all of the above as system-level shortcuts so they appear in Spotlight without Shortcuts.app configuration.

### Chat panel (optional, hideable, capability-gated)

- A collapsible panel for natural-language search.
- Backend: `FoundationModelService` only. **Hidden entirely on Macs without Apple Intelligence.**
- Function-calls into the same internal tool registry that App Intents uses (read-only set + tag writes).
- Strict on-device. No network. No bundled-model fallback in v1 (would likely disappoint at small model sizes; revisit if Apple's models materially improve or user demand justifies).

### iCloud Drive support

Roots may live under `~/Library/Mobile Documents/com~apple~CloudDocs/`. Indexer policy:

- `URLResourceKey.ubiquitousItemDownloadingStatusKey` checked before opening any iCloud file.
- If `current` (downloaded), index normally.
- If `downloaded` but stale, trigger `FileManager.startDownloadingUbiquitousItem(at:)` and re-check on the next pass.
- If `notDownloaded`, the grid renders a placeholder + cloud icon; hashing/Vision deferred until download completes.
- `ubiquitousItemIsDownloadingKey` drives a download-progress badge in the grid tile.
- Hashing iCloud-only files is skipped to avoid surprise multi-GB downloads; user explicitly clicking "Analyze" or opening the file triggers download.

---

## 7. Sequencing — what to ship in what order

**Phase 0 — Housekeeping**
- ✓ Create `feat/file-viewer-rewrite` branch
- Strip the import-based code paths and 3D Universe/Folder views (Globe code parked, will be reworked in Phase 8)
- Wipe-and-start-fresh DB scaffold; legacy DB file ignored on disk

**Phase 0.5 — v0.1 (validate the filesystem-native UX)**
The smallest possible Muse that proves the new direction is right. Ship and use for a week before building anything else.
- Multi-root sidebar (just folder tree, no starring yet)
- Root picker via NSOpenPanel + security-scoped bookmarks
- FSEvents watcher on the active folder (non-recursive)
- ThumbnailCache (QLThumbnailGenerator → on-disk PNG cache)
- Grid view driven by `FileNode`
- Image viewer (existing overlay reused)
- Quick Look fallback for everything else
- Right-click → Open With…
- Path breadcrumb in toolbar

**Phase 1 — Core viewers + indexing**
- Indexer (SHA-256 hashing + path tracking + identity reconciliation matrix)
- PDFViewer, TextViewer, MarkdownViewer (the read-only trio)
- Starred folders + persistence

**Phase 2 — Universal viewer fill-out**
- RAW, PSD preview, SVG, code (syntax highlighted), .rtf, video, audio, 3D, fonts, archives
- .docx/.doc/.pages routed to Quick Look

**Phase 3 — On-device intelligence (manual)**
- Analyze button: Vision tags, OCR, faces, dominant color, feature prints
- Tag panel (manual + auto)
- Smart sort (color, object, face, has-text, visual cluster)

**Phase 4 — Duplicates**
- Find Duplicates pane
- Three clusterers (byte-exact, visual, filename)
- Smart suggestions where signal is strong
- Move-to-Trash with confirmation

**Phase 5 — Search**
- FTS5 across filename + OCR + caption + tag labels
- Current-folder vs everywhere toggle
- Saved smart searches

**Phase 6 — App Intents automation**
- All intents listed in §6 (App Intents subsection)
- `AppShortcutsProvider` registration for Spotlight
- Documentation for users on Shortcuts integration

**Phase 7 — Chat panel (capability-gated)**
- Foundation Models on Apple Intelligence-capable Macs only
- Tool routing through the internal tool registry shared with App Intents
- Hidden on incapable Macs, no error, no nag

**Phase 8 — Polish & visualizations**
- Globe view rework (current-folder content)
- Water shader polish — alt-visualization toggle for image folders
- (Future) Globe depicting subfolders

---

## 8. Deferred design work (not blocking Phase 0.5)

### Onboarding flow
First-run UX needs its own design pass. Generalists landing on Muse should understand "this is a folder viewer + smart features" within the first 30 seconds. Likely beats:
1. Welcome panel naming what Muse is
2. Pick your first folder (NSOpenPanel, store as security-scoped bookmark)
3. Brief "tap a file to preview, right-click to open elsewhere" hint
4. Skip / "I know what I'm doing" path

Lives in a sibling plan doc when designed.

### Settings / Preferences scope (Phase 6)
Will need: roots management, "show subfolders" default, AI on/off master kill, default sort, default view mode, chat panel visibility (when capable), thumbnail cache size, hidden-files toggle, dedup thresholds.

### Chat panel placement (Phase 7)
Collapsible right panel, separate window, or Cmd+K command-palette overlay? Defer to Phase 7 design.

### Branding / look-and-feel
Keep: typography + masonry-style grid + parallax tilt + lime-green selection + custom titlebar logo + water shader (polished as alt visualization). The visual character of the existing app survives.

## 9. Performance budgets (preliminary)

| Operation | Target | Notes |
|---|---|---|
| App cold start to interactive | <1.5s | |
| Open a folder (1k files, indexed) | <100ms | |
| Open a folder (10k files, indexed) | <300ms | Lazy-load tiles after this |
| Open a folder (100k files, first time) | <2s with progress | Hashing happens in background |
| Search FTS (current folder) | <50ms | |
| Search FTS (entire library) | <500ms | |
| Find duplicates (current folder) | <5s for 5k files | Pre-filter aggressively |
| Find duplicates (everywhere) | No interactive guarantee | Background queue, progress UI |
| Visual "find similar" (current folder) | <300ms | After candidate prefilter |
| Thumbnail load (cache hit) | <16ms | One-frame perception |
| Thumbnail load (cache miss) | <200ms | QLThumbnailGenerator cold |

---

## 10. Out of scope (v1)

- Editing of any kind (image, PDF, text, video) — delegated to specialist apps via Open With
- Cloud sync / cross-device — local-only, no exceptions
- Direct integration with Apple Photos.app — not technically possible for files outside its library
- iOS/iPadOS — macOS only
- **MCP server** — incompatible with App Store sandbox; reopens only if distribution channel changes
- External AI agent integration (Claude Desktop, Comet, Cursor) — same reason
- Pricing / monetization — free forever, no IAPs, no subscriptions, no ads, no analytics, no paid tier
- Persistent jobs across launches — quitting Muse cancels in-flight scans
- HNSW / LSH approximate nearest neighbor — scope-by-default + prefilter is enough for v1

---

## 11. Definitions

- **Muse root** — a folder on disk the user has pointed Muse at. Any folder qualifies. Multiple roots allowed.
- **Starred folder** — a folder anywhere in any root that the user has pinned for quick access.
- **Indexed library** — the union of all files currently or previously seen by the indexer across all roots, persisted in the SQLite DB.
- **Active folder** — the folder currently selected in the sidebar; the grid shows its contents.
- **Asset kind** — Muse's classification of a file used to pick the viewer.
- **Smart suggestion** — Muse's pre-pick of "keep this one" in a duplicate group, only made when signal is rock solid.
