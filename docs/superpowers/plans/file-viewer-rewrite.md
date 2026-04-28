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
| Q15 | Min macOS | macOS 26 — full access to Apple Foundation Models, latest Vision APIs. |
| Q16 | File types | Universal viewer — see §4 for the full table. Anything unsupported falls back to Quick Look. |
| Q17 | Scale target | Large (100k+ files). Architecture decisions (FTS5, paged queries, vector index, lazy folder load) all assume large libraries. Small libraries pay no penalty. |
| Q18 | File identity | Hybrid — primary key is content SHA-256, with path tracking. Move a file in Finder → tags follow. Edit content → `previous_hashes` lookup reattaches tags. |
| Q19 | View modes | **Keep:** Grid (default), Globe (reworked for current-folder content). **Drop:** Universe, Folder-3D. |
| Q20 | Sidebar contents | Just the folder tree. Tags / starred / saved searches live elsewhere in the UI (TBD). |
| Q21 | Search scope | Default = current folder. Toggle in search bar for "search everywhere" (entire indexed library). |
| Q22 | DB migration | Wipe & start fresh. Existing user-data file at `~/Library/Application Support/Muse/` left untouched on disk for now (new app simply doesn't read it). |
| Q23 | Distribution | **OPEN — see §8.** App Store (sandbox + bookmark friction) vs. direct + notarization (Bridge's path). Affects everything from filesystem access to update mechanism. |
| Q24 | Primary user persona | **OPEN — see §8.** Designers (mood-board curation), photographers (shoot culling), or generalists (Downloads-folder triage). Defaults & dedup heuristics will tune to this. |
| Q25 | Globe & water shader | **OPEN — see §8.** Differentiator (lean in, polish them) or vestigial from old identity (cut clean). |
| Q26 | Multi-root | **Multi-root, Finder-favorites style.** Sidebar shows roots as top-level groups; each independently navigable; starred folders pinned across all roots in their own section above. |
| Q27 | Identity reconciliation | Byte-identical files at different paths = **one** `files` row with multiple `paths` children. **Tags shared across all paths of the same content.** Deliberate; documented for users. See §4 for the full decision matrix. |
| Q28 | Captions | Captions come from **Vision**, not the LLM. Object/scene labels + OCR text + dominant color, concatenated and stored on `files.caption` for FTS indexing. (Foundation Models was wrong API for this.) |

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
    ThumbnailCache.swift          (QLThumbnailGenerator + on-disk cache, keyed by file_id)
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
    OfficeViewer.swift            (NSAttributedString for .docx/.rtf, QL fallback for .doc)
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
    MCP/
      MCPServer.swift             (stdio JSON-RPC; tool registry)
      MuseTools.swift             (search, list, getMetadata, addTag, etc.)
      Manifest.swift              (advertised tool schemas)
    AppIntents/
      MuseAppIntents.swift        (Shortcuts/Siri integration)

  Editing/                        (REMOVED — see §6 — kept slot for future)

  Fluid/                          (kept — water shader is alt grid visualization)
    FluidSim.swift
    FluidDistortion.metal

  Settings/
    PreferencesView.swift         (roots, AI options, dedup thresholds, MCP toggle)
    Roots.swift                   (multi-root manager)
```

### Key external dependencies
- **GRDB.swift** — already used; keep for SQLite layer (schema is new).
- **SQLite FTS5** — bundled in macOS SQLite, just needs a `CREATE VIRTUAL TABLE` migration.
- **MLX** (Apple) — Swift package for local LLM inference fallback.
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

---

## 4. Data model

### `files`
| column | type | notes |
|---|---|---|
| `id` | TEXT PK | UUID |
| `content_hash` | TEXT UNIQUE | SHA-256 |
| `kind` | TEXT | AssetKind raw value |
| `size_bytes` | INTEGER | |
| `width` | INTEGER NULL | images/video |
| `height` | INTEGER NULL | |
| `duration_seconds` | REAL NULL | video/audio |
| `created_at` | INTEGER | filesystem birth time |
| `modified_at` | INTEGER | filesystem mtime |
| `last_seen_at` | INTEGER | last time indexer saw this file on disk |
| `caption` | TEXT NULL | AI-generated description |
| `dominant_color` | TEXT NULL | hex |
| `feature_print` | BLOB NULL | VNFeaturePrintObservation data |
| `previous_hashes` | TEXT NULL | JSON array — for tag survival across edits |

### `paths`
| column | type | notes |
|---|---|---|
| `id` | TEXT PK | |
| `file_id` | TEXT FK → files.id | |
| `absolute_path` | TEXT UNIQUE | |
| `bookmark_data` | BLOB | security-scoped bookmark for sandbox |
| `is_alive` | INTEGER | 1 if still on disk |

A file can have multiple paths (hardlinks, copies). Removing the last alive path is what makes a file "gone."

### `tags`
| column | type | notes |
|---|---|---|
| `id` | TEXT PK | |
| `file_id` | TEXT FK | |
| `label` | TEXT | |
| `source` | TEXT | "manual" or "vision" or "caption" |
| `confidence` | REAL NULL | 0..1 for AI tags |

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
- `files_fts(content_hash, basename, ocr_text, caption)` — populated by Indexer

### Vector index — explicit scaling rules
- Feature prints stored as `BLOB` on `files.feature_print`.
- **Visual dedup and "find similar" default to current-folder scope.** "Search everywhere" exists but is opt-in with a "this may take a while" disclaimer.
- Even at folder scope, candidates are pre-filtered by **resolution bucket** (within ±10%) and **dominant-color hash** (8-bit perceptual hash) *before* computing cosine. This typically prunes the candidate set 50–500×.
- Brute-force cosine over the surviving candidates only. At realistic folder sizes this stays interactive (<200ms).
- Library-wide scans run on a background queue and present a progress UI. No interactive guarantees there.
- HNSW / LSH not implemented in v1. Trigger to add: a real user with a 100k+ "everywhere" workflow that's painful in practice. Until then, scope-by-default is the cheaper answer.

### Identity reconciliation matrix
The indexer encounters a path on disk. It computes the SHA-256 hash. Then:

| Path state | Hash state | Interpretation | Action |
|---|---|---|---|
| New path | New hash | Brand new file | Create `files` row + `paths` row |
| New path | Existing hash | Copy / hardlink of known content | Keep one `files` row; add new `paths` row. **Tags are shared across both paths.** |
| Known path | Same hash | Unchanged file | Touch `last_seen_at` on `files`; nothing else |
| Known path | New hash | File was edited in place | Update `files.content_hash` to new value; append old hash to `files.previous_hashes` JSON array. **Tags remain attached** — they followed the path. |
| Known path absent on disk | n/a | File deleted or moved away | Mark `paths.is_alive = 0`. If no other alive paths point to this `files` row, the file is "gone" but its row + tags persist for ~30 days in case it reappears (e.g. detached drive). |
| New path | New hash that matches a `previous_hashes` entry | Lightroom-style export from a known original | **Tags do NOT auto-attach.** Exports are deliberately treated as new files. (Reasoning: an export is a derivative, not the original; conflating them surprises users.) |

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

- **"Find Duplicates"** runs three clusterers in parallel and merges results into `DuplicateGroup`s with `reason` annotated.

- **Smart Sort** dropdown applies:
  - Dominant color (sort by HSV hue)
  - Object/scene category (group by top-confidence tag)
  - Face count (descending)
  - Has-text (group by OCR-text presence)
  - Visual cluster (k-means or DBSCAN over feature prints; group label = cluster id)

### MCP server

Runs as a child-process MCP server when the user enables "Allow agents to talk to Muse" in preferences. Exposes the following tools:

**Reads**
- `searchFiles(query, scope, limit, kinds?, tags?)` → `[FileSummary]`
- `listFolder(path, kinds?, sortBy?)` → `[FileSummary]`
- `getFile(id)` → `FileDetail` (includes paths, tags, caption, dominant color)
- `getThumbnail(id, size)` → image bytes
- `getTextContent(id)` → text/markdown/code content
- `findSimilar(id, limit)` → visual neighbors via feature print
- `findDuplicates(scope)` → `[DuplicateGroup]`
- `listRoots()` → `[Root]`
- `listTags()` → `[String]`

**Writes (Muse DB only — never disk)**
- `addTag(fileId, label)`
- `removeTag(fileId, label)`
- `starFolder(path)` / `unstarFolder(path)`
- `saveSmartSearch(name, query)` / `deleteSmartSearch(id)`
- `markDuplicateKeeper(groupId, fileId)` (record user's choice; doesn't delete)

**Never:** moveFile, renameFile, deleteFile, editFile, createFolder, etc. Agents wanting file ops use the OS directly.

### Chat panel (optional, hideable, capability-gated)

- A collapsible panel for natural-language search.
- Backend: `FoundationModelService` only. **Hidden entirely on Macs without Apple Intelligence.**
- Function-calls into the same tools the MCP server exposes (read-only set + tag writes).
- Strict on-device. No network. No bundled-model fallback in v1 (would likely disappoint at small model sizes; revisit if Apple's models materially improve or user demand justifies).

### App Intents

- "Open Muse to folder X" (Shortcut)
- "Find duplicates in current folder" (Shortcut)
- "Tag selected file as Y" (Shortcut, runs while Muse is foregrounded)
- Used by Siri / Spotlight / Shortcuts.

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

**Phase 6 — Agent integration**
- App Intents (Shortcuts/Siri)
- MCP server with tool manifest
- Preferences toggle to enable/disable
- Documentation for connecting Claude Desktop / Perplexity Comet

**Phase 7 — Chat panel (capability-gated)**
- Foundation Models on Apple Intelligence-capable Macs only
- Tool routing through the same MCP tool registry
- Hidden on incapable Macs, no error, no nag

**Phase 8 — Polish & visualizations** (gated on Q25 outcome)
- If "differentiator": Globe view rework (current-folder content) + water shader as alt-visualization toggle for image folders
- If "vestigial": cut both, replace with a simpler "view as cards / list / details" trio
- (Future) Globe depicting subfolders

---

## 8. Open questions (still need user decision)

### Q23 — Distribution channel
**Mac App Store** vs **direct download + notarization** (Bridge's path).

| Factor | App Store | Direct + notarized |
|---|---|---|
| Filesystem access | Strict sandbox; security-scoped bookmarks for *every* folder; refresh pain | No sandbox; arbitrary disk access; simpler |
| MCP server (child process) | Restricted/forbidden under sandbox | Trivial |
| Discovery | App Store search | Manual / website |
| Updates | App Store auto-update | Sparkle or similar |
| Revenue | 15-30% cut, paid-up-front or subscription | DIY (Paddle, FastSpring) |

The MCP server alone is a strong nudge toward direct distribution — running a child JSON-RPC process from a sandboxed app is painful at best. Bridge, Photo Mechanic, and Eagle all distribute direct.

### Q24 — Primary user persona
Pick one. Defaults, dedup heuristics, the "first 5 minutes" UX, and the marketing all bend to whichever you pick.

| Persona | Bias |
|---|---|
| **Designer / mood-boarder** | Default sort = visual cluster. Smart sort emphasizes color/scene. Dedup is gentle (lots of "almost the same" reference shots are valuable). Hero use case: "find me everything blue and minimal." |
| **Photographer (culling shoots)** | Default sort = date taken. Dedup is aggressive on byte-exact and resolution dupes. Star-rating + reject workflow matters. Hero: "rate these 800 RAWs in 20 minutes." |
| **Generalist (Downloads triage)** | Default sort = date modified. Dedup is mainly byte-exact + filename. Quick Look fidelity matters more than smart features. Hero: "what's in this 50GB Downloads folder?" |

You can serve all three eventually, but v1 should be opinionated about one.

### Q25 — Globe view & water shader: keep or cut?
Bridge has nothing like them. They're load-bearing for old-Muse's identity but vestigial for the new direction. Honest options:

- **Keep + lean in** — they become Muse's "this is the one I'd remember" features. Polish, document, market around them.
- **Cut clean** — remove both, replace Globe with traditional grid/list/details view-mode triad. Saves ~2 weeks of Phase 8 work.
- **Hide, don't cut** — keep code, ship disabled-by-default, decide later. (Usually a trap — disabled features rot.)

### Q26 — Settings/Preferences scope (lower priority)
Will need: roots management, dedup thresholds, "show subfolders" default, AI on/off (master kill switch), MCP server enable/disable, default sort, default view mode, chat panel visibility (when capable). Spec when we get to Phase 6.

### Q27 — Chat panel placement
Collapsible right panel, separate window, or Cmd+K command-palette overlay? Defer to Phase 7 design.

### Q28 — Branding / look-and-feel survival
Current app has lime-green selection, parallax tilt, water shader, masonry grid, custom titlebar logo. What survives? Tied to Q25. Suggestion: keep typography + parallax + lime-green selection regardless; tie water shader and globe to Q25 outcome.

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

## 10. Out of scope

- Editing of any kind (image, PDF, text, video) — delegated to specialist apps via Open With
- Cloud sync / cross-device — local-only, no exceptions
- Direct integration with Apple Photos.app — not technically possible for files outside its library
- iCloud Drive smarts beyond what the OS gives us automatically
- iOS/iPadOS — macOS only

---

## 11. Definitions

- **Muse root** — a folder on disk the user has pointed Muse at. Any folder qualifies. Multiple roots allowed.
- **Starred folder** — a folder anywhere in any root that the user has pinned for quick access.
- **Indexed library** — the union of all files currently or previously seen by the indexer across all roots, persisted in the SQLite DB.
- **Active folder** — the folder currently selected in the sidebar; the grid shows its contents.
- **Asset kind** — Muse's classification of a file used to pick the viewer.
- **Smart suggestion** — Muse's pre-pick of "keep this one" in a duplicate group, only made when signal is rock solid.
