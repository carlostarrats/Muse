# Muse — session log (archive)

Full chronological narrative of every working session. Moved out of
`CLAUDE.md` (2026-06-18) to keep the always-loaded project notes lean —
the durable rules + a compact index live in `CLAUDE.md`. Nothing here is
load-bearing for a fresh session beyond what that index already surfaces;
read an entry when you need the full "why" behind a specific change.

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
  rewrites the stored **path prefixes** in `paths.absolute_path`,
  `tags.parent_dir`, AND `starred_folders` (pin path + the renamed folder's own
  label) — all path-keyed tables. So manual tags AND pins survive (tags are
  keyed `(file_id, parent_dir)`; pins are never auto-pruned, so they must be
  migrated explicitly). Collections / FTS / analysis are `file_id`-keyed
  (content hash) and need no migration. The SQL lives in
  `FolderRenameMigration.apply(_:old:new:newName:)` (one transaction) and is
  **unit-tested directly against an in-memory GRDB** (`FolderRenameMigrationSQLTests`);
  the pure rule `FolderRenameMigration.rewrite(path:old:new:)` mirrors it. The
  prefix match uses `SUBSTR(col,1,LENGTH(:old)+1) = :old || '/'` (plus exact
  `= :old`), **not** `LIKE`, so "%"/"_" in paths can't break it and a sibling
  like "…/OldStuff" is never caught by old "…/Old".
  - **Ordering / atomicity (review-hardened).** `apply` first **clears stale
    rows already under the NEW prefix** (deletes orphan pins, deactivates orphan
    alive `paths`) so a forgotten pin / dead row can't collide on a UNIQUE
    constraint and roll back the whole transaction. The destination didn't exist
    on disk (FolderOps refuses a real collision), so those rows are stale —
    EXCEPT a case-only rename, which is safe because every index + the pre-clear
    use BINARY collation (the source's other-case rows aren't matched). The
    migration is `await`-ed to completion **before** the post-rename
    reselect/re-index, so the re-index can't insert alive rows at the new path
    ahead of the rewrite. Failure surfaces a `folderOpError` (no silent `try?`).
- **Tree refresh.** `FolderNode` gained a weak `parent` ref + `reloadChildren()`
  (re-reads children even when already loaded). Subfolder rename →
  `node.parent?.reloadChildren()`; **root** rename →
  `BookmarkStore.rootRenamed(_:to:)` mints a fresh security-scoped bookmark from
  the new URL (the inode-based old scope still covers the moved folder), swaps
  access, and updates the stored `Root` display name → the `$roots` sink
  rebuilds the sidebar (the renamed root's subtree collapses — fresh node). If
  the selected folder is the renamed one **or an ancestor of it**, the grid is
  reselected at the rewritten path after the migration (best-effort tree node,
  else a transient node) so it's never stranded on a dead path.
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
- Tests: `FolderOpsTests` (validation incl. leading-dot + case-only rename),
  `FolderRenameMigrationTests` (pure rewrite rule + `FolderRenameMigrationSQLTests`
  running the real migration SQL against an in-memory GRDB: paths/tags/pins,
  sibling-safety, SQL wildcards, stale-target-pin no-rollback, case-only rename).
- **QA:** three adversarial review rounds (parallel reviewers) + fixes — the
  rounds found and closed: un-migrated pins, fire-and-forget migration racing the
  re-index on the alive-path unique index, ancestor-of-selection stranding,
  case-only-rename false collision, hidden-name silent create, and a stale-target
  UNIQUE rollback. Final verdict: ready to merge; build + full `MuseTests` green.

### Hero-close deselect + collection-card hover veil — 2026-06-17 (on `feat/next-14`)

Two small live UI fixes. Build + full `MuseTests` suite green; two parallel
adversarial reviews + a fix-verification round (the one IMPORTANT finding is
folded in).

- **Hero close no longer flashes the tile's selected state.** Closing the hero
  image viewer (Esc / ✕ / backdrop tap) used to land the underlying grid tile in
  its *selected* look — image shrunk inward 10pt + selection ring — for a moment
  before deselecting, reading as a stray hover/outline flash. Two root causes:
  (1) `TileView.isSelected` (`GridView.swift`) included `|| selectedFile?.id ==
  file.id`, which (since `FileNode.id` is a per-instance UUID and the opened tile
  is that same instance) was true *exactly* when the tile is already hidden by the
  `selectedFile?.url == file.url` opacity gate — visually dead, but it kept
  `isSelected` true through the whole return flight; (2) nothing cleared
  `selectedFiles` on close (the first click of the opening double-click had
  single-selected the file), so the revealed tile stayed selected. Fix: dropped
  the dead `selectedFile?.id` clause, and `HeroImageViewer.startClose()` now calls
  `appState.clearSelection()` *first* — while the tile is still hidden — so the
  0.15s deselect animation finishes invisibly during the ~0.34s flight and the
  tile reveals at normal size, unselected. Also satisfies "Esc leaves nothing
  selected." For parity (review-found IMPORTANT), `completeDelete` and the
  mid-burn `onDisappear` also `clearSelection()` the just-trashed file, so an
  **Undo** can't restore a tile already wearing the ring. The error
  ("Couldn't move to Trash") path deliberately leaves the selection intact.
- **Collection cards hover like the grid tiles.** `CollectionCard`
  (`CollectionsRow.swift`) replaced the `.scaleEffect(1.025)` hover-grow with the
  grid's calm dark veil — a rounded-rect black overlay at 0.2 opacity, gated
  `hovering && !isActive` (the active card's accent border is its cue), drawn
  under both the hairline and accent borders. Cards are one-click (drill into the
  collection), so no resize. A `RoundedRectangle().fill` self-clips to its path,
  so no black bleeds past the cover's rounded corners.

### Sidebar folder-click reliability + reorder rebuilt as a live gesture — 2026-06-18 (on `feat/next-15`)

Chased a rare "clicking a top-level folder doesn't select on the first try" bug
and, in doing so, rebuilt sidebar folder reordering end-to-end (all in
`SidebarView.swift`; one comment added to `AppState.swift`). Each root cause was
confirmed empirically (instrumented logging / one-variable diagnostic builds)
before fixing, per systematic debugging.

- **Click-twice was SwiftUI `.onDrag`.** Top-level rows were drag-to-reorder via
  `.onDrag`, which installs an AppKit drag source on the shared hosting view and
  intercepts mouse-down across the WHOLE row — a click with a hair of movement
  was read as a (cancelled) drag and the selection tap was dropped. Proven by a
  diagnostic build with `.onDrag` removed (clicks became 100% reliable).
  `simultaneousGesture(TapGesture)` did NOT fix it (the interception is below
  SwiftUI's gesture layer), and confining `.onDrag` to a small grip subview also
  didn't (same shared hosting view). **Do NOT reintroduce `.onDrag` on sidebar
  rows.**
- **Reorder is now a live `DragGesture`, not pasteboard drag-and-drop.** A trailing
  grip (shown on hover) drives a `DragGesture` in a named coordinate space
  (`reorderSpace`). The dragged row is hidden in place (its layout slot stays so
  the others can part around it) and an **opaque copy** (`draggedRowOverlay`,
  grip included) is drawn as a ScrollView overlay following the cursor — because
  **`LazyVStack` ignores `.zIndex`**, a top overlay is the only reliable way to
  keep the dragged row above the rows it passes (zIndex made it translucent when
  moving DOWN — later rows painted over it). The other rows **part** to open a gap
  (`rowShift`), and a faint insertion line marks the gap as an overshoot cue.
- **Two earlier dead-ends, documented so they aren't retried.** (1) The previous
  pasteboard reorder could move a folder DOWN but never UP — the per-row
  `.onDrop(of:[.text])` (reorder) was **shadowed** by the row's
  `.onDrop(of:[.fileURL])` (move grid images in), so reorder drops only ever
  reached the end-zone (append). Going live-gesture removed the `.text` drop
  entirely, so the fileURL move drop is unshadowed again. (2) A floating drag
  *image* (the pasteboard preview / a rendered chip) looked like a detached
  tooltip; the rows-part-to-make-way model with an opaque in-list-styled overlay
  is what reads as "the row itself moving."
- **Slot math uses a drag-start frame snapshot** (`dragStartFrames`), NOT live
  frames: `.offset` *does* change a row's `frame(in: .named(reorderSpace))`
  (confirmed by logging — the dragged row's measured frame tracked its offset),
  so reading live frames back into the slot computation would feed back on itself.
  The dragged row is excluded from the slot/line math (`otherReorderRoots`). The
  insertion **line** position deliberately uses LIVE `rootFrames` so it sits at
  the *parted* gap.
- **Commit is non-animated** (`Transaction.disablesAnimations`): after parting the
  rows are already in their final visual positions, so reordering the array +
  clearing the offsets in one transaction leaves everything in place and the
  dropped row simply appears in the gap — no snap-back / pass-through. This relies
  on `bookmarks.$roots` delivering **synchronously** (the AppState sink has no
  `.receive(on:)`); a note was added at that sink so it isn't made async.
- **Polish:** hover fill (and the grip) are suppressed on rows the dragged row
  passes over (a `sidebarReordering` environment flag); the grip is only
  hit-testable while visible-or-dragging so the invisible strip can't swallow
  scroll-drags; a safety net resets drag state if the dragged root vanishes
  mid-drag (gesture `.onEnded` may not fire on teardown); long folder names
  truncate before the grip.
- **Known limitation (placement stays correct — `commitReorder` is identity-based;
  only in-flight visuals degrade):** reorder is tuned for COLLAPSED top-level
  folders (the common case). Dragging a folder while it's *expanded*, or within a
  long *scrolled* root list (off-screen rows aren't measured by `LazyVStack`), can
  show an oversized/misaligned gap.
- **QA:** build + full `MuseTests` suite green; three adversarial review passes
  (two parallel finders + a fix-verification pass). The finders' MAJORs
  (stuck-state on interrupted gesture, off-screen/expanded edge cases) were fixed
  or documented; the verification pass confirmed the fixes introduce no
  regression to the normal drag.

### Sidebar folder sort modes + live file counts — 2026-06-18 (on `feat/next-15`)

Added a sort control + a live per-folder count to the sidebar's top-level
folders (spec: `docs/superpowers/specs/2026-06-18-folder-sort-and-counts-design.md`,
plan: `docs/superpowers/plans/2026-06-18-folder-sort-and-counts.md`). Built via
subagent-driven development (4 tasks, each spec+quality reviewed + a final
whole-feature review on opus + one review-fix). Build + full `MuseTests` green.

- **Sort control** — a `Sort: <mode> ▾` menu at the top of the sidebar
  (`SidebarView.sortHeader`): **Manual** (default) · **Name** (A→Z, localized) ·
  **Date Modified** (newest first) · **Size** (largest first), checkmark on
  active, persisted via `AppSettings.folderSortMode`. Pure comparator
  `FolderSort.order` (`Models/FolderSortMode.swift`) — name tiebreak, missing-stat
  sorts last — unit-tested.
- **Manual stays draggable; sorted modes are READ-ONLY.** The live drag-reorder
  gesture is gated to Manual (`reorder:` passed to `FolderTreeNode` only when
  `sortMode == .manual`); Name/Date/Size show a sorted *copy*
  (`displayedReorderableNodes`) and never mutate the manual order
  (`BookmarkStore.roots`). So a sort never overwrites your hand arrangement.
- **Live per-folder count** at the row's trailing edge. It follows the
  show-subfolders toggle so it always matches the grid: off → immediate files,
  on → recursive files. On hover in Manual mode the count swaps in place for the
  ≡ grip (`showGrip = reorder != nil && isHovered && !isReordering`); during a
  drag the in-list row falls back to the count (the grip rides the floating
  overlay). The iCloud row shows a count, no grip; subfolders show neither.
- **Size + Date Modified are recursive aggregates** (toggle-independent): total
  bytes of all files under the folder, and the newest mtime anywhere under it
  (NOT the folder's own inode date — deep changes don't bubble up). The COUNT is
  viewable/grid-files; size sums all files. All from one walk per folder.
- **`FolderStat` + `FolderStats.compute`** (`Filesystem/FolderStat.swift`, pure +
  nonisolated): immediate + recursive counts, recursive size, recursive latest
  mtime; mirrors the grid's file notion (every non-folder entry; packages count
  as files, not descended-as-folders) so the count matches exactly. Unit-tested.
- **`FolderStatCache`** (`Filesystem/FolderStatCache.swift`, `@MainActor`): caches
  a stat per top-level folder, computes off-main, and keeps stats LIVE via a
  single FSEvents watch over ALL root paths (`FolderWatcher.watch(urls:)`, new
  overload). A content change anywhere under a root recomputes just that root
  (debounced ~0.4s). `AppState` owns it, drives `update(roots:)` from
  `rebuildRootNodes` (launch + roots add/remove + iCloud discovery), and forwards
  its `objectWillChange` (like `stars`) so the sidebar re-renders.
- **Perf (review fix):** `update(roots:)` only restarts the watcher + recomputes
  on a real root-SET change (a `watchedPaths` set diff) and only walks
  newly-added roots — so a drag-reorder (same roots, same contents) does zero
  re-walks and zero watcher restarts. A late detached recompute can't resurrect
  a removed root's stat. Toggling show-subfolders is recompute-free (both counts
  live in the cached stat). `compute` passes `showHidden: false` (commented:
  must track `AppState.showHidden` if that ever becomes user-facing).
- **Known limitation (placement always correct; only in-flight visuals/edge
  cases):** for a long *scrolled* root list, off-screen roots aren't measured by
  `LazyVStack` so a count may lag until visible; otherwise counts refresh within
  ~0.5s of a change.
- **QA — independent review pass (2 parallel reviewers + a fix-verification):**
  both returned "ready to merge, no Critical." Fixed: `FolderStatCache.handle`
  now drops hidden/dotfile-segment changes (`rootForMediaChange`) — `.muse`
  sidecars are written inside every root on each analyze pass, and without the
  filter each one triggered a redundant full re-walk + spurious re-render (the
  walk uses `skipsHiddenFiles`, so they never change the count). Added the
  spec-required sort-mode `UserDefaults` round-trip test + empty-input and
  equal-metric name-tiebreak coverage. Deferred (non-blocking, documented):
  packages are descended-into (matches the grid — the binding invariant — over
  the spec's literal wording), ~0.7s in-app-mutation lag (spec-acceptable),
  `LazyVStack` doesn't slide-animate a sort reorder.

### Ghost-row reconcile + tag-chip sort control — 2026-06-18 (on `feat/next-16`)

Spec approved live; plan: `docs/superpowers/plans/2026-06-18-ghost-rows-and-tag-sort.md`.
Build + full `MuseTests` suite green.

- **The bug (TWO symptoms, ONE root cause).** Searching "photo" returned many
  blank document-icon tiles, and the "Conversations" collection card said 5 but
  opened showing 1. Verified against the live DB + disk: `IMG_0466.jpg` and 4 of
  the 5 `Conversations` members were **gone from disk** yet still `is_alive=1`,
  fully analyzed. The Indexer only ever reconciles files **present** on disk —
  nothing marks a file dead when it's deleted/moved OUT of a folder externally
  (the grid hides this because it enumerates the disk, but **search**
  (`SearchService` resolves alive paths) and **collection counts**
  (`CollectionStore.fetchAll` COUNT DISTINCT alive `file_id`) query by
  `is_alive`, so the ghost rows leaked through — as unrenderable blank tiles in
  search, and as an inflated card count vs. the existence-filtered opened list).
- **Fix — `PathReconciler`** (`Filesystem/PathReconciler.swift`, pure + DB,
  unit-tested). On a **fresh folder selection only** (per the user's "per-folder
  on load" choice — self-heals as you browse, no startup cost), inside the
  existing off-main folder load: diff the enumerated on-disk set against the DB's
  alive rows **scoped to that folder** (`inScope` mirrors `FolderEventFilter`'s
  recursive/direct-child rule) and flip the vanished rows to `is_alive=0`
  (`markDead`, counted via a pre-SELECT so it's exact + idempotent). Runs BEFORE
  the tag-chip counts compute (so chips exclude the dead files too) and refreshes
  the collection cards (`CollectionsEngine.shared.reload()`) when anything died,
  so a stale "5" corrects immediately (and a now-1-member intent collection falls
  below the ≥3 threshold and drops on the next organize pass).
  - **Evicted-iCloud guard:** modern dataless-in-place files keep their real name
    and ARE enumerated (safe); an OLD-STYLE `.<name>.icloud` placeholder is hidden
    (not enumerated) but NOT gone — `isEvictedPlaceholder` detects the sibling and
    keeps the row alive. Only genuinely-absent files die. This is filesystem
    PRESENCE only — NOT a size/mtime poll (does not violate the iCloud
    content-refresh override; that ban was about metadata oscillation).
  - **No data migration** (per `muse-fix-code-not-my-data`): the forward code
    reconciles on visit; the user's existing ghosts clear the moment the folder
    is opened. Search-relevance left as-is (user's choice: keep OCR text matches —
    "photo" matching screenshots that contain the word "Photo" is intended).
- **Tag-chip sort control** (Task 3). New `TagSortMode` enum (`Models/`,
  `.count`/`.alphabetical`) + `AppSettings.tagSortMode` (mirrors `folderSortMode`,
  default `.count`). `AppState.tagSortMode` is `@Published`; a change sinks →
  persist + `reloadTagChips()`. `TagChipLoader.ordered(_:sortMode:)` now branches
  (Most Used = count desc, alpha tiebreak; A→Z = label only) and feeds BOTH chip
  call sites (the inline folder-load path + `reloadTagChips`). Toolbar gains a
  `tag`-icon `Menu` (`ContentView.tagSortMenu`) placed between the grid sort
  cluster and the show-subfolders toggle, disabled on the Collections page.
- Tests: `PathReconcilerTests` (scope/diff pure + in-memory GRDB markDead/
  reconcile incl. non-recursive subfolder safety), `TagChipLoaderOrderTests`
  (count vs alpha vs default). Full suite green.
- **Live-review fixes (same session):**
  - **Tag-sort was one selection behind** — `$tagSortMode` fires in `willSet`,
    so the sink's `reloadTagChips()` read the OLD `self.tagSortMode` and ordered
    the chips backwards. `reloadTagChips(sortModeOverride:)` now takes the value
    the publisher delivered (same `willSet` gotcha noted at the `bookmarks.$roots`
    sink).
  - **Controls that fight an active search are disabled while searching** — the
    grid sort cluster (menu + direction arrow), the tag-sort menu, the
    show-subfolders toggle (it re-loaded the whole folder listing, dropping you
    out of results), and the Collections toolbar button (toggling it yanked you
    out + re-highlighted a folder). All gated on `AppState.isSearchActive`.
  - **Search scope checkmark didn't move** — the All/This-Folder magnifier menu
    mutated the `searchMenuTemplate`'s items, but `NSSearchField` caches its own
    copy and ignores later mutations. A scope change now reinstalls a FRESH
    template (correct checkmarks), tracked by `Coordinator.appliedAllFolders` so
    it only rebuilds on a real change.
- **QA — two parallel adversarial reviews + a fix-verification round.** Found and
  fixed two real issues in the reconcile:
  - **(Critical) False-empty mass-delete.** `FolderReader.files` /
    `enumerateRecursive` return `[]` for BOTH a genuinely-empty folder AND a
    failed read (transient permission loss, or an iCloud folder not materialized
    on a cold launch). Reconciling on a false-empty marked the WHOLE folder's
    `is_alive` rows dead — the iCloud data-loss class this project guards against.
    Fix: when `present` is empty, a directory probe gates the reconcile — a read
    that THROWS (the path failed reads take to return `[]`) → skip; a genuinely
    readable-but-empty folder → reconcile (cleans its ghosts). Probe only runs on
    the empty path (short-circuit), off-main in the load task.
  - **(Important) `markDead` not chunked.** A single `IN (?,…)` over >999 vanished
    paths exceeds `SQLITE_MAX_VARIABLE_NUMBER`, throws, and (under `try?`) silently
    cleans nothing — failing on the large-deletion case the feature exists for.
    Fix: chunk at 500 (matches the codebase), summed in one transaction. Test:
    `testMarkDeadChunksPastSQLiteVariableLimit` (1500 paths).
  - The verification round confirmed both closed with no regression (precedence,
    chunk math, atomicity, threading all checked). Full `MuseTests` suite green.

### Accessibility pass on post-2026-06-13 UI + reorder keyboard path — 2026-06-18 (on `feat/next-17`)

An accessibility audit of every UI surface added since the last full WCAG AA
pass (2026-06-13), plus a small search-bar tweak. Build + full `MuseTests` suite
green; two adversarial review rounds (the MAJOR + MINORs below were review-found
and fixed, then re-verified).

- **Search bar min width 320 → 280** (`SearchBar.swift`). The `.principal`
  toolbar item is centered in the leftover space between the leading/trailing
  toolbar groups (native macOS — NOT window-centered), and the old 320pt floor
  made the toolbar collapse the side buttons into the `»` overflow sooner as the
  window narrowed. 280 lets the field yield ~40pt before the buttons collapse;
  the off-center rest position is inherent to `.principal` and unchanged.
- **Three VoiceOver information gaps fixed** (visuals untouched — pure a11y
  metadata): (1) **tag-chip counts** were hover-only (`TagChipsRow`), so
  screen-reader users couldn't reach them — now surfaced as the chip's
  `accessibilityValue` ("N files"); the decorative hover number is
  `accessibilityHidden`. (2) **grid file-name caption** was redundant — the tile
  is already one a11y element via `.accessibilityElement(children: .ignore)` with
  `accessibilityLabel(file.basename)`, which already excludes the caption (so the
  initial "hide the caption" change was reverted as a no-op; just a clarifying
  comment remains). (3) **Duplicates "KEEP"** was conveyed by color + a
  silently-disabled checkbox only. The FIRST attempt (hide the badge + put the
  reason on the disabled Toggle's `accessibilityHint`) was a **review-caught
  MAJOR**: macOS VoiceOver doesn't reliably focus disabled controls and hints are
  off by default, so that LOST the info entirely. Correct fix: the keeper status
  rides a focusable, enabled element — the thumbnail ZStack is collapsed
  (`accessibilityElement(children: .ignore)`) and labeled "Suggested keeper" on
  keeper rows (hidden on non-keepers); the Delete toggle stays a sibling below,
  independently operable.
- **Verified NOT broken** (no change needed): the grid selection redesign still
  exposes `.isSelected` (selection isn't color-only); all new icon-only buttons
  (sort-direction, tag-sort, collections "+", hero Share/Open-With,
  share-collection) carry `.help`, the codebase's established + sufficient macOS
  VoiceOver-naming pattern.
- **Reorder was mouse-only — the one real WCAG 2.1.1 (Keyboard) gap — now
  closed.** The sidebar's drag-to-reorder grip had no keyboard/VoiceOver
  equivalent (it's a bare `DragGesture`, deliberately NOT `.onDrag` which ate
  clicks — see the 2026-06-18 sidebar session). Added **Move Up / Move Down** to
  the folder right-click menu (`FolderTreeNode` in `SidebarView`) and **Move
  Folder Up / Down** to the Edit menu (`MuseApp`), both gated to Manual sort and
  edge-disabled, reusing the identity-based `BookmarkStore.reorder(_:relativeTo:
  placeAfter:)` — the drag gesture is untouched. The context menu gates on the
  existing `reorder != nil` signal (non-nil ⟺ Manual + reorderable root); the
  Edit menu gates on `AppState.folderSortMode == .manual`.
  - **Folder sort mode promoted to `AppState.folderSortMode`** (`@Published`,
    persisted via a Combine sink mirroring `tagSortMode`; the sink captures no
    `self`, so no `[weak self]` needed). It lived in `SidebarView`'s local
    `@State`; the Edit-menu gating needs one reactive source shared with the
    sidebar, which now reads it via a computed `sortMode` and writes through
    `setSortMode`. Sidebar behavior is unchanged.
  - **Both keyboard paths index the DISPLAYED (resolved-bookmark) root order**,
    not the full `bookmarks.roots` — matching the drag path and what the user
    sees, so a root whose security-scoped bookmark fails to resolve (and is
    hidden from the sidebar) can't make a move appear to do nothing or leave an
    edge button enabled-but-inert (both were review-found MINORs).
- **QA — two adversarial review rounds + fixes.** Round 1 found the Duplicates
  MAJOR (disabled-control hint) + the reorder list-divergence MINOR; round 2
  confirmed those closed and caught one stray `bookmarks.roots.count` vs
  `displayedReorderableRoots.count` boundary mismatch (fixed). No new tests
  (pure-view a11y metadata + menu wiring over the already-tested
  `BookmarkStore.reorder`); build + full suite green.

### Search-bar width + standardized hero-close nav — 2026-06-18 (on `feat/next-18`)

Two small live UI fixes. Build + full `MuseTests` suite green.

- **Search bar back to a fixed 320pt** (`SearchBar.swift`). The a11y pass had
  dropped it 320 → 280, but the `.principal` toolbar slot centers the field and
  sizes it to its content clamped to `minWidth` — the centered slot does NOT
  stretch/shrink with the window, so the field is fixed-width regardless of the
  value. True window-responsive scaling isn't achievable there without
  `maxWidth: .infinity`, which expands aggressively and collapses the side
  buttons into the `»` overflow. So per the user's preference, reverted to a
  fixed 320 (a non-scaling 280 bought nothing).
- **Both hero-close paths return the nav identically** (`ContentView.swift`).
  The X button calls `HeroImageViewer.startClose()` synchronously (in the
  button's event transaction), so `viewerDismissing = true` flips up front and
  the toolbar/search bar returns instantly with the flight ("never gone"). The
  Escape path went `viewerClosing = true` → `.onChange` → `startClose()`, and
  that extra hop made the nav return a beat later ("delayed/abrupt"). Fix: the
  ContentView Escape handler now sets `viewerDismissing = true` (animated) up
  front in the same transaction as `viewerClosing`, so Escape matches X. Net
  behavioral change is just this one line + the 320; `startClose` itself is
  unchanged (comment-only).
- **The search-bar "flash" investigation (documented so it isn't re-chased).**
  A long systematic-debugging pass (screen-recorded at 120fps, per-region luma
  analysis) traced a "very slight app-wide brightness flash" on close to the
  **native toolbar/search field materializing over the still-fading dark
  backdrop** as it returns during the flight — the search field's shadows are
  revealed mid-fade. It is INHERENT to having the nav present during the close:
  the macOS toolbar pops in (it can't truly fade), and keeping it always-present
  to avoid the pop shows empty grey item "wells" over the hero (rejected).
  Tried + rejected: a window-bg/SwiftUI backstop (flash isn't grey-window), a
  solid-color backdrop (not the vibrancy material), faster backdrop fade-out
  (backdrop already fully faded before unmount — not the cause), an
  always-present toolbar with faded contents (empty wells), and "toolbar returns
  only after the image lands" (no flash, but the user disliked losing the
  instant return). DECISION: keep the instant return on both paths and accept
  the very slight flash — the flash and the "never gone" feel are the same
  event. Do not reintroduce the always-present-toolbar or after-land approaches.

## 2026-06-18 — `main` / release v1.1.2 — hero-close Escape regression fix

- **Escape-to-close needed two presses (regression from the next-18 change
  above).** The next-18 "standardize nav return" pass had ContentView's Escape
  handler set `viewerDismissing = true` (animated) up front in the same
  transaction as `viewerClosing = true`, to shave the `.onChange` hop's "beat."
  That extra, separate `@Published` write — which toggles the toolbar
  mid-transaction — regressed Escape into needing TWO presses: the first press
  returned the nav over the hero but the close itself didn't complete; a second
  Escape was needed to actually dismiss. The X button was never affected because
  it funnels the whole close through a single trigger (`startClose()`), which
  sets `viewerDismissing` and `isClosing` together.
- **Fix:** ContentView's Escape handler now fires ONLY `viewerClosing = true`
  and lets `startClose()` (run via HeroImageViewer's `viewerClosing` onChange)
  own the entire close, including bringing the nav back itself — exactly as the
  X button does. Both paths are now truly identical. The only behavioral
  trade-off is the one next-18 tried to remove: on Escape the nav returns one
  render hop later than on the X button (cosmetic). Verified: rebuilt Debug,
  hero now closes on a single Escape. Recorded as a durable "must not break" in
  CLAUDE.md (don't add a separate `viewerDismissing` write to the Escape path).
- Released as **v1.1.2** (direct distribution + Sparkle; `scripts/release.sh`).

## 2026-06-18 — `feat/next-19` — "New Collection from Selection"

- **New right-click action.** The grid tile context menu (`SelectionActionsMenu`
  in `Views/SelectionMenu.swift`) gains a top-level **"New Collection from
  Selection"** button, placed immediately under the existing "Add to Collection"
  submenu. It creates a brand-new collection from the effective selection (the
  multi-selection, or just the right-clicked tile) and adds those images to it.
  Purely additive — nothing existing changed behavior; only the file's top doc
  comment was refreshed (it was stale re: the already-shipped Move-to-Folder and
  remove actions too).
- **Reuses the existing building blocks, no new storage logic.** The handler
  `newCollectionFromSelection()` mirrors `addToCollection(_:)` but creates the
  destination first: resolve paths→file IDs (`CollectionStore.fileIDs`), then
  `CollectionStore.createManual` (auto-names `"Collection N"` via
  `ManualCollectionName.next` inside one atomic write transaction, `model_version
  = 'manual'`, returns the new id), then `addFile` per file, then
  `CollectionsEngine.reload()`. One guard the add-to-existing path lacks: if the
  file-ID lookup is empty, it bails instead of creating an orphan empty
  collection.
- **After-create UX:** stay put, no navigation — matches the Collections-page
  "+" button. The new collection surfaces in the Collections page on the reload.
- **Why the empty-collection window is safe:** a `'manual'` collection is
  protected from the recluster's stale-deletion the instant its row exists
  (`protectedCollectionIDs` covers all `model_version='manual'` rows regardless
  of membership), so a recluster racing between create and the addFile loop can't
  drop it. `reload()` is a pure read (`fetchAll`), so it never reclusters/renames
  the manual collection.
- **Verification:** Debug build succeeded; full `xcodebuild -scheme Muse test`
  suite green (28 cases, 0 failures, incl. the manual-collection naming/visibility
  tests). Independent code review found no blockers. Spec:
  `docs/superpowers/specs/2026-06-18-new-collection-from-selection-design.md`.

## 2026-06-18 — `feat/next-19` — name-it modal for new collection

- **Follow-up to the above.** Creating a collection from the selection now
  **prompts for a name** instead of auto-naming silently. Right-click "New
  Collection from Selection" opens a **"Name Collection"** modal — the same
  native `.alert` + `TextField` pattern as the sidebar's Rename Folder dialog
  (`ContentView.swift`, beside the Rename-Folder alert). Field starts empty with
  a "Collection name" placeholder; **Create** (default — Return confirms) /
  **Cancel**.
- **Prompt-first, so Cancel creates nothing.** The effective selection's file
  paths are captured at right-click time (`AppState.requestNewCollection(fallback:)`
  → `pendingNewCollectionPaths`), and **no DB write happens until confirm**.
  `confirmNewCollection()` trims the name, bails on blank/empty-selection, then
  `createManual` → `rename(to: typedName)` → `addFile` loop → `reload()`.
  `cancelNewCollection()` just clears the pending state. This avoids the
  create-then-delete dance (and the `setHidden` tombstone that a collection
  "delete" would leave) that an after-the-fact prompt would have needed.
- **State lives in AppState** (`newCollectionRequest`, `newCollectionNameDraft`,
  `pendingNewCollectionPaths`) with the actions in `AppState+Filters.swift`,
  mirroring how `renameFolder` is structured. The old view-local
  `newCollectionFromSelection()` immediate-create helper was removed from
  `SelectionMenu.swift`; the button now calls `appState.requestNewCollection`.
- **Reuse:** `createManual` (auto-name + atomic insert) + `CollectionStore.rename`
  (plain UPDATE) + `addFile`; no new store API. Duplicate collection names are
  allowed (matches the existing inline collection rename — no uniqueness check);
  validation is non-empty only.
- **Verification:** Debug build green; full `xcodebuild -scheme Muse test` suite
  green (0 failures). Spec + plan:
  `docs/superpowers/specs/2026-06-18-name-collection-modal-design.md`,
  `docs/superpowers/plans/2026-06-18-name-collection-modal.md`.

## 2026-06-18 — `feat/next-19` — unify the Collections-page "+" onto the name modal

- **One create-a-collection experience.** The Collections-page **"+"** button no
  longer creates an auto-named empty collection immediately — it opens the same
  **"Name Collection"** modal as the grid's "New Collection from Selection"
  (`CollectionsPage.createCollection()` now just calls
  `appState.requestNewCollection()`).
- **Generalized the shared request/confirm** (`AppState+Filters.swift`):
  `requestNewCollection(fallback path: String? = nil)` — `nil` means no selection
  (the "+" case, empty `pendingNewCollectionPaths`); a path still captures the
  effective selection (grid right-click). `confirmNewCollection()` now creates the
  named collection whenever the name is non-empty and only seeds members when a
  selection was captured (`if !paths.isEmpty`). Dropping the old
  empty-selection/empty-ids *create* guards is what lets "+" make an empty named
  collection; it also makes the right-click path create-on-confirm even if the
  selected files don't resolve, rather than silently doing nothing.
- **Adaptive alert copy** (`ContentView.swift`): "Creates a new collection." with
  no selection, "Creates a collection from the selected images." with one.
- **Untouched:** the hero viewer's own "add to a new collection" path
  (`ViewerInfoColumn` → `createManual(queue:name:fileID:)`) keeps its inline name
  field; only the Collections-page "+" was in scope. Reuses createManual + rename
  + addFile — no new store API, no schema change.
- **Verification:** Debug build green; full `xcodebuild -scheme Muse test` suite
  green (0 failures). Spec + plan:
  `docs/superpowers/specs/2026-06-18-unify-collections-plus-modal-design.md`,
  `docs/superpowers/plans/2026-06-18-unify-collections-plus-modal.md`.

## 2026-06-18 — `feat/next-20` — sort the Collections page

- **The Collections card grid is now sortable.** It was hardcoded to display
  alphabetical A→Z; now the existing toolbar **sort menu** + **direction arrow**
  drive it. On the Collections page the menu lists only the modes that apply to a
  *group* — **Name / Date Created / Date Modified** — hiding Size/Kind/Color/Shape
  (per-image properties a collection lacks). The arrow flips each (A→Z/Z→A,
  Newest/Oldest first), reusing `SortMode.defaultAscending` / `directionLabel`.
- **Pure helper** (`Intelligence/Collections/CollectionSort.swift`): a
  `nonisolated enum CollectionSort` with `Item(id/name/createdAt/updatedAt)` and
  `order(_:by:reversed:)`, mirroring `FolderSort`. Name uses
  `localizedStandardCompare` (numeric-aware, matching the grid's `.name`); the
  date modes are newest-first with a name tiebreak; `reversed` flips the whole
  result (same strategy as `SmartSorter.apply`). Unit-tested in
  `MuseTests/CollectionSortTests.swift` (6 cases).
- **State** (`AppState`): `collectionSortMode` (default `.name`) +
  `collectionSortReversed` (default `false`), both `@Published` and persisted in
  `AppSettings` via `.dropFirst()` Combine sinks — **independent** of the grid's
  `sortMode`/`sortReversed`, the same isolation tag/folder sorts already have.
  Defaulting to Name-not-reversed reproduces the old A→Z exactly.
  `toggleCollectionSortDirection()` just flips the flag; the card grid re-sorts
  reactively off the `@Published` change (no `resort()` — unlike the grid there's
  no stored array). `SortMode.collectionCases = [.name, .dateCreated,
  .dateModified]` is the menu's source list.
- **Toolbar** (`ContentView.swift`): `sortMenu` + `sortDirectionButton` are now
  context-aware via the `isCollectionsPage` ternary (computed `cases` + a
  computed `Binding`, so the Picker isn't duplicated); the sort cluster's
  `.disabled(isCollectionsPage || isSearchActive)` relaxed to
  `.disabled(isSearchActive)`. Drilled INTO a collection or searching falls back
  to the grid `sortMode` as before. The tag-sort menu stays disabled on the page.
- **`CollectionsPage.sorted`** maps `engine.collections` → `CollectionSort.Item`,
  calls `order(...)`, and reorders by the returned ids (`id` is the PK, so the
  `Dictionary(uniqueKeysWithValues:)` is collision-safe).
- **Review:** three independent finder passes (correctness / removed-behavior +
  cross-file / cleanup + conventions) found no correctness bugs; the one applied
  cleanup collapsed the `sortMenu` if/else into a single computed-binding Picker
  to match the neighboring ternary style. No CLAUDE.md rule violated, no schema
  change (`collections.created_at`/`updated_at` already exist).
- **Verification:** Debug build green; full `xcodebuild -scheme Muse test` suite
  green (0 failures, incl. the 6 new `CollectionSortTests`). Spec + plan:
  `docs/superpowers/specs/2026-06-18-collections-page-sort-design.md`,
  `docs/superpowers/plans/2026-06-18-collections-page-sort.md`.

## 2026-06-18 — `feat/next-21` — global Image Layout (masonry + fixed ratios)

- **The grid can now lay out images in a fixed aspect ratio, globally.** A new
  toolbar button (`square.grid.2x2`, between Collections and the mood button)
  opens a modal that picks the layout for **every** grid — all-tags, a single
  tag, inside a collection. Masonry stays the default; the alternatives are 11
  fixed ratios (1:1, 9:16, 16:9, 4:5, 5:4, 6:7, 7:6, 2:3, 3:2, 3:4, 4:3).
- **No new geometry engine.** Key realization: feeding `MasonryGeometry.compute`
  a *uniform* aspect array makes its shortest-column packer lay out an exact
  row-major grid. So `GridView.recompute()` just branches: a fixed layout passes
  `Array(repeating: imageLayout.aspect!, count:)`; masonry passes per-image
  ratios from `AspectRatioCache` as before. The masonry path is byte-for-byte
  unchanged. `UniformGridLayoutTests` locks the uniform-aspect → aligned-grid
  invariant (a characterization test on existing `MasonryGeometry` behavior).
- **No cropping.** A fixed-ratio tile is bigger/smaller than the image, but
  `TileView.tile` already draws `Rectangle().fill(moodPalette.tileFill)` (the
  zip/non-image grey) behind a `.aspectRatio(.fit)` image — so the image
  letterboxes inside the tile with grey fill, for free. Selection ring, hover
  veil, captions, virtualization, delete all carry over untouched.
- **One perf guard:** `onChange(of: aspects.version)` now early-returns when a
  fixed layout is active — a decoded thumbnail reporting its real ratio must NOT
  relayout a uniform grid (it would churn every frame). In masonry (`aspect ==
  nil`) it recomputes on every decode exactly as before. A separate
  `onChange(of: appState.imageLayout)` recomputes (animated, like the column
  slider) on a layout switch, so the grid re-lays-out live behind the open modal.
- **Model + persistence:** `Models/ImageLayout.swift` — `enum ImageLayout: String,
  CaseIterable` (declaration order == modal display order), with `displayName`,
  `aspect` (height÷width; ratio names are width:height, so 9:16 → 16/9 tall),
  `iconKind`, and `resolve(_:)` (default masonry). Persisted via
  `AppSettings.imageLayout` and mirrored on `AppState.imageLayout` (@Published,
  `didSet` write-back — the `mood` pattern). Unit-tested (`ImageLayoutTests`, 8).
- **The modal** (`Views/ImageLayoutSheet.swift`): InfoSheet chrome (600×720, 24pt
  title, shared close button), a 4-col `LazyVGrid` of the 12 `ImageLayout` tiles,
  then a "Common Sizes" reference list. `LayoutTile` mirrors a grid tile's
  selection but **blue-only** (the modal isn't mood-colored): square grey box →
  on select the square fill shrinks/insets to blue with the gap showing through,
  inside a rounded **8pt** ring (matching the grid). `FlatButtonStyle` removes the
  plain-button pressed darken so it goes straight hover→blue. `LayoutIconView`
  draws the 4 generic 44×44 previews (mason / square / portrait / landscape) all
  at one footprint. Tuned over several rounds with the user (uniform icon size,
  grid-style inset selection, no press state, square fill + curved ring only).
- **Cleanup:** the circular hover-✕ was copy-pasted in InfoSheet and the new
  sheet → extracted `Views/SheetCloseButton.swift`, now used by both.
- **Scope note (by design, not a gap):** the collection **PDF export** keeps its
  own masonry pack (it's a print layout, not an on-screen grid); the hero viewer
  fills (single image, not a grid). "Every grid" means the browsing grids.
- **Review:** four finder passes (line-by-line / removed-behavior + cross-file /
  cleanup + conventions) found **no correctness bugs** — masonry preserved, guard
  correct in every path, aspect math right, no force-unwrap/NaN/id-collision, and
  the virtualization rule intact (the modal's `LazyVGrid` is over 12 fixed cases,
  not the file set). Refuted: "use `SelectionStyle.accent()` not blue" — the
  modal is deliberately blue-only per the design and sits on a non-mood sheet.
  Applied the one real finding (the duplicated close button).
- **Verification:** Debug build green; full `xcodebuild -scheme Muse test` suite
  green (0 failures, incl. 8 `ImageLayoutTests` + 2 `UniformGridLayoutTests`).
  Visually QA'd in the running app: toolbar button placement, fixed-ratio grid
  (uniform tall tiles, no crop, grey letterbox), and the modal selection. Spec +
  plan: `docs/superpowers/specs/2026-06-18-image-layout-design.md`,
  `docs/superpowers/plans/2026-06-18-image-layout.md`.

## 2026-06-18 — `feat/next-22` — tile background (grid backdrop + PDF export)

- **The grey behind images/file cards is now user-selectable, globally.** A new
  "Tile Background" section in the mood popover (`MoodPickerView`) sets the
  backdrop independent of the app mood: **None** (transparent), **Auto** (follows
  the mood tile color — the default, so existing users see no change), and three
  fixed neutrals **Light** `#FAFAFA` / **Dark Grey** `#555555` / **Black**
  `#0D0D0D`. Motivation: a grey image on the grey backdrop disappears; the fix is
  tonal, so neutral densities beat a custom color picker (it would mostly make
  things worse). Grouped Automatic vs Static; the Auto swatch shows the live mood
  color (so it visibly changes), None is a slash glyph.
- **Model:** `Models/TileBackground.swift` — `enum TileBackground: String,
  CaseIterable` with `displayName`, `backdropRGB(for:) -> MoodRGB?` (the single
  resolver; nil = transparent, auto = mood `tileRGB`, statics = fixed), `fill(for:)
  -> Color` (`.clear` for None), and `resolve(_:)` (default `.auto`). Persisted via
  `AppSettings.tileBackground`, mirrored on `AppState.tileBackground` (@Published,
  `didSet` write-back — the `mood`/`imageLayout` pattern). Unit-tested
  (`TileBackgroundTests`, 5).
- **Masonry = Auto only.** Masonry has no letterbox, so it always uses Auto;
  only fixed ratios honor a static pick. Centralized as
  `AppState.effectiveTileBackground` (`imageLayout == .masonry ? .auto :
  tileBackground`) and consumed uniformly by `tileFill`, the picker's selection
  highlight, the file-card text color, and the export. The stored pick is
  preserved while in masonry (restores on switching back to a ratio); the picker
  section dims + disables with a note.
- **Grid:** `GridView.TileView`'s two `Rectangle().fill(...)` (image tile +
  file card) now read `appState.tileFill`. The grid *background* (mood) is
  unchanged. The non-image card's internal filename adapts to the backdrop
  luminance via `SelectionStyle.relativeLuminance` (`cardNameColor` — light text
  on dark, dark on light; None follows the page) so names stay readable on
  Black/Dark Grey.
- **PDF export now mirrors the on-screen grid** (supersedes next-21's "PDF keeps
  its own masonry pack" scope note). `CollectionPDFExporter` takes `layoutAspect`
  + `tileBackdrop`: the **paper page stays white**, but each image's backdrop is
  filled with the chosen color (None = no fill → white/transparent through PNGs),
  and a fixed ratio feeds a uniform aspect array so tiles match the grid's ratio.
  Color fidelity: `MoodRGB.cgColor` (sRGB) matches the on-screen tile hue.
- **File cards export too.** `ShareCollectionButton.imageURLs` → `exportURLs`
  (all non-folder members, not just image/raw/psd). The exporter decodes images
  via ImageIO and falls back to QuickLook (`QLThumbnailGenerator`, `.all` — the
  same macOS type icon / content preview the grid cards show) for everything
  else, drawn on the backdrop like any image. Decode runs with **bounded
  concurrency** (8-wide `withTaskGroup`, order preserved by index) so a
  file-card-heavy export doesn't serialize N QuickLook XPC round-trips.
- **Image Layout modal is now mood-independent.** `ImageLayoutSheet`'s tiles were
  tinted by `moodPalette.tileFill`; they now use a fixed default grey
  (`Mood.paperPalette.tileFill`) with fixed label/icon colors, so the modal looks
  the same regardless of the app color or tile-background choice.
- **Also:** `ImageLayout.masonry` displayName "Mason" → "Masonry"
  (`ImageLayoutTests` updated). None swatch got `.contentShape(Rectangle())` so
  the whole swatch is tappable, not just the label.
- **Review:** three finder passes (correctness / runtime-QA / cleanup-conventions)
  + a focused verifier on the concurrency refactor. No correctness bugs;
  effective-routing consistent, persistence sound (no spurious init write-back),
  aspect/pagination index-aligned. Acted on two findings: serial QuickLook →
  bounded concurrency, and generic→sRGB CGColor for export hue fidelity. Left by
  design: picker shows Auto in masonry (intended), white caption band in PDF
  (paper always white), ThumbnailCache decode duplication (off-main, CGImage,
  no cache — justified).
- **Verification:** Debug build green; full `xcodebuild -scheme Muse test` suite
  green (0 failures, incl. 5 `TileBackgroundTests`). Spec + plan:
  `docs/superpowers/specs/2026-06-18-tile-background-design.md`,
  `docs/superpowers/plans/2026-06-18-tile-background.md`.

## 2026-06-18 — `feat/next-23` — Duplicates modal redesign (grid-style selection + keep-one protection)

Reworked the Find-Duplicates review modal (`DuplicatesView`) around four user
asks. The old modal locked you into the finder's single suggested keeper (its
Delete toggle was `.disabled(isSuggestedKeeper)`) — you couldn't override it —
and rendered fill-cropped 140² thumbnails with a checkbox.

- **The keeper is a suggestion, not a lock.** Removed the disabled-keeper toggle.
  A group now opens with its **non-keeper copies pre-marked for delete** (a smart
  default), fully overridable. The green **KEEP** badge is no longer pinned to the
  finder's pick — it tracks **survivors**: any tile not currently marked for
  delete. Delete the suggested keeper and KEEP jumps to whatever you leave kept;
  keep several in a 5-copy group → several KEEP badges.
- **Grid-style selection, modal-fixed colors.** Each duplicate is a `DuplicateImageTile`
  mirroring a grid tile / the Image Layout modal: image **fits (never crops)** on
  a square whose backdrop is **transparent**, so letterbox gaps and the selection
  inset reveal the modal's grey card behind it (not white). Marking for delete
  insets the image and draws a **blue ring** at the outer edge — **no tint**, so
  the picture stays fully visible. Colors are fixed (`Color.accentColor`, system
  greys), NOT the mood-adaptive grid accent — a modal shouldn't shift with the
  background palette. Click the tile **or** the Delete checkbox; both set the same
  state. Subtle hover-darken on toggleable, unselected tiles only.
- **Reveal in Finder per tile.** A frosted magnifier button (top-trailing,
  mirroring the KEEP badge top-leading) → `NSWorkspace.activateFileViewerSelecting`.
- **A group can never be fully deleted (protection).** At least one copy always
  survives. In a 3+ copy group the last survivor is **locked** (disabled checkbox,
  tap gated, "At least one copy must be kept" tooltip + VoiceOver value); in a
  **2-copy** group the survivor stays clickable and **swaps** instead (selecting it
  frees the other), so you don't have to deselect first. To remove the last copy,
  delete it from the grid or in Finder.
- **Cross-group correctness (review fix).** `DuplicateFinder` appends byte-exact +
  filename + visual groups over the same files, so one file can be in multiple
  groups while the delete set (`selected: Set<URL>`) is global. The "keep one"
  rule is therefore evaluated against **every** group a file belongs to, not the
  first — `wouldEmptyAGroup` checks all of them, the swap only fires for a file in
  a single 2-copy group, and seeding is reconciled by `rescued` (un-marks a
  survivor for any group left fully selected when overlapping groups disagree).
  `seedDefaults` also prunes stale selections from a prior scan.
- **Pure, tested rules.** Extracted `Intelligence/Dedup/DuplicateDeleteRules.swift`
  (`seed` / `rescued` / `isLocked` / `selecting`) — mirrors the `GridSelection` /
  `CollectionSort` pattern (pure enum, unit-tested; UI stays a thin renderer).
  `DuplicateDeleteRulesTests` (17) cover the invariant, the 2-copy swap, locking,
  and cross-group overlap/rescue. Also added an `@ObservedObject` on the shared
  `DuplicateFinder` (the old `body` read `.shared.groups` directly and never
  subscribed) and a VoiceOver `accessibilityAction` on the tile.
- **Review:** three finder passes (correctness / removed-behavior+cross-file /
  cleanup-conventions) + an adversarial verifier on the group-aware rules. The
  cross-group invalidation was the one real bug, now fixed and proven (rescue is
  remove-only, so a single pass reaches a fixpoint — no loop needed). Left by
  design: `DuplicateImageTile`/`AsyncThumbnail` don't share `GridView.TileView`
  (that one is mood-adaptive + grid-coupled; this modal is fixed-color by intent);
  conservative locking when a file sits in multiple groups (errs toward keeping).
- **Verification:** Debug build green; full `xcodebuild -scheme Muse test` suite
  green (0 failures, incl. 17 `DuplicateDeleteRulesTests`). Drove the running app
  and confirmed the redesign visually (grid-style tiles, KEEP-follows-survivors,
  blue inset ring, reveal button); UI-automation of a fresh re-scan was blocked by
  macOS Apple-event TCC, so the seeded-default open state was user-verified.

## 2026-06-18 — `feat/next-24` — synchronized toolbar-icon recolor on mood change

Small UI-polish pass. On a background-mood change the navigation **toolbar icons**
flip white↔black at slightly **different moments** (staggered), and the group as a
whole lagged the background fade.

- **Cause.** The toolbar icons carried no explicit color — they inherited the
  system **label color**, which flips when `preferredColorScheme(moodPalette.scheme)`
  changes (`ContentView` line ~340). Each toolbar item is its own native
  `NSToolbarItem` (a bridged `NSHostingView`), and AppKit runs an **appearance
  crossfade per item** on the scheme flip — those crossfades aren't synchronized,
  hence the stagger. The whole group also trailed the background because the icons
  only recolored via AppKit's appearance change, not the SwiftUI mood animation.
- **Fix.** Drive the icon color **explicitly** from the mood and animate it with
  the **same `.animation(.easeInOut(duration: 0.35), value: moodPalette)`** the
  background already uses (`ContentView` body, line ~73). New
  `MoodPalette.iconColor` (`.white` in a dark scheme, `.black` in light) + a
  file-private `View.moodToolbarIcon(_:selected:)` helper that pairs the color with
  that animation. Applied to all eight toolbar icons (sort, tag-sort, sort-
  direction, show-subfolders, Collections, Image Layout, mood, info). For the two
  `Toggle`s (`showSubfolders`, mood `paintpalette`) `selected:` keeps the native
  white-on-accent icon while "on"; "off" follows the mood in step with the rest.
  The search field manages its own appearance (`SearchBar`) and isn't touched.
- **Outcome / ceiling.** Icons now recolor together and in lockstep with the
  background. A native `Toggle`'s own AppKit crossfade can't be fully suppressed
  from SwiftUI, so a hair of softness on the toggles is the floor — declared
  acceptable rather than rebuilding the toolbar as custom views (over-engineering
  for a sub-second transition). No unit test: `iconColor` returns a SwiftUI `Color`
  whose equality is unreliable to assert, and the logic is a trivial one-liner —
  the behavior is visually verified. Two files changed (`ContentView.swift`,
  `Models/Mood.swift`).
- **Verification:** Debug build green; full `xcodebuild -scheme Muse test` suite
  green (0 failures). Drove the running app and confirmed the synchronized recolor
  on Light↔Dark switches.

## 2026-06-18 — `feat/next-25` — accessibility pass on post-`next-17` features

Second accessibility pass (the first, `feat/next-17`, covered the post-2026-06-13
UI). Scope: everything added since — `feat/next-18` → `feat/next-24` — plus an
app-wide sweep of icon-only buttons that the audit surfaced. Additive accessibility
annotations only; no layout or behavior change. Build + full `xcodebuild -scheme
Muse test` suite green (0 failures).

**1 — New-feature VoiceOver gaps (next-18→24).**

- **Image Layout button (next-21):** icon-only toolbar button had only `.help()`,
  so VoiceOver fell back to the SF Symbol name ("square grid 2x2"). Added
  `.accessibilityLabel("Image Layout")`.
- **Tile Background swatches (next-22):** selection was conveyed by ring color
  only, and two swatch names ("Auto", "Light") collide with the mood swatches in
  the same popover. Added `.accessibilityLabel("Tile background: <name>")` +
  `.isSelected` trait. Gave the older `MoodSwatch` the `.isSelected` trait too for
  parity.
- **Duplicates tile (next-23):** the tile sets `.accessibilityElement(children:
  .ignore)`, which collapsed it into one element and **hid the reveal-in-Finder
  button from VoiceOver entirely**. Re-exposed it as a named action
  (`.accessibilityAction(named: "Reveal in Finder")`) — VoiceOver/Full-Keyboard
  reach it via the actions rotor while the tile's primary action stays "toggle
  delete".
- next-18 (search/hero-close), next-20 (collections sort — reuses the already
  labeled sort controls), next-24 (icon recolor — visual only) needed nothing.

**2 — Menu-bar reach for a mouse-only action (next-19).**

"New Collection from Selection" existed ONLY in the grid right-click menu, so
keyboard/VoiceOver users had no path to it. Added **"New Collection from
Selection…"** to the `Collections` menu (`MuseApp.swift`), calling
`appState.requestNewCollection(fallback: "")` and gated on a non-empty selection
(so the empty fallback path is never used — `effectiveSelectionURLs` returns the
selection when `selectedFiles` is non-empty).

**3 — App-wide icon-only-button label sweep.**

`.help()` sets the macOS AXHelp (a hint/tooltip), NOT the VoiceOver *name*. Every
icon-only `Button`/`Menu`/`Toggle` that relied on `.help()` alone got an explicit
`.accessibilityLabel`:

- Toolbar: show-subfolders toggle, Collections, About, Sort, Tag order, Background.
- Collections header (`CollectionsRow`): save/cancel rename (`HeaderIconButton`,
  label from its `help`), Delete (`TrashButton`), Back arrow (`BackArrowButton`).
- Collections page "+" (`AddCollectionButton`); hero Share (`ShareButton`) + the
  palette color swatch ("Copy color #…", named after its copy action); collection
  Share (`ShareCollectionButton`); the shared sheet close ✕ (`SheetCloseButton`);
  Duplicates reveal + close ✕.
- Grid column slider: the two decorative min/max grid icons are
  `.accessibilityHidden(true)`; the `Slider` itself is labeled "Images per row".
- Sidebar reorder grip: `.accessibilityHidden(true)` rather than labeled — it's a
  mouse-only drag affordance whose tap merely re-selects the row (already
  reachable), and the accessible reorder path is Edit → Move Folder Up/Down.
  Exposing an undraggable "grip" would only add a dead control.
- Active tag chip: `.isSelected` trait (the filled-pill state was visual only).

**4 — `CollectionCard` rework (the deeper one).**

The card is a tap target (`.onTapGesture`, not a `Button`), so VoiceOver saw two
loose `Text`s (name, count) with NO action — unactivatable and unlabeled as a
control. Collapsed it into one element: `.accessibilityElement(children: .ignore)`,
`.accessibilityLabel("<name>, <n> item(s)")` (pluralized), `.isButton` (+
`.isSelected` on the active card, whose state was accent-border-only), a primary
`.accessibilityAction` that opens the collection, and a named "Delete Collection"
action re-exposing the otherwise right-click-only delete.

**Pitfalls navigated (logged so the next pass doesn't relearn them):**

- **Never `.accessibilityElement(children: .ignore)` on a `Button`.** It can strip
  the button's activation action (that's why the non-Button `DuplicateImageTile`
  and `CollectionCard` must re-add an `.accessibilityAction`). On a real `Button`,
  `.accessibilityLabel` ALONE overrides the text-derived name and keeps the action
  — so the Tile Background swatch (a Button) just gets the label, no `children:
  .ignore`.
- **`.help` and `.accessibilityHint` both write macOS AXHelp.** Setting both is
  ambiguous; keep one. On `CollectionCard` the `.help(name)` is the keeper (it
  drives the tooltip that reveals the full name when it truncates at
  `.lineLimit(1)`), so the redundant `.accessibilityHint` was dropped — the
  `.isButton` trait already signals activatability.
- **Don't override the name of a control that has visible text** (label-in-name):
  the tag chip and the "Edit" pill keep their text-derived names; only the
  icon-only controls got explicit labels.

**Files:** `ContentView.swift`, `MuseApp.swift`, `Views/MoodPickerView.swift`,
`Views/DuplicatesView.swift`, `Views/CollectionsRow.swift`,
`Views/CollectionsPage.swift`, `Views/ShareCollectionButton.swift`,
`Views/SheetCloseButton.swift`, `Views/GridView.swift`, `Views/TagChipsRow.swift`,
`Views/SidebarView.swift`, `Views/Viewer/ShareButton.swift`,
`Views/Viewer/ViewerInfoColumn.swift`.

**Verification.** Debug build green; full test suite green. Changes are declarative
a11y modifiers with no visual footprint, so build + tests are the verification; a
live VoiceOver pass (manual screen-reader interaction) was not automatable here.

## 2026-06-19 — `fix/toolbar-icon-drift` — toolbar icons drift during grid resize

**Symptom (from a tester's screen recording).** On a 2018 Intel MacBook Pro
(Sequoia), three of the four trailing toolbar icons — Image Layout, mood
(paintpalette), and About (info) — drifted vertically up and down in a slow,
repeating loop while the tester resized the grid (the column-count slider) during
a search ("cassette"). The Collections icon (the first trailing item) stayed put.
Intermittent; neither the tester nor the owner could reliably reproduce it on
demand.

**Investigation (frame-by-frame on the recording).** Cropped the toolbar icon
strip and measured each icon's top-edge Y per frame:

- Collections: rock-steady the entire clip.
- Image Layout / mood / info: a **perfectly linear, non-autoreversing sawtooth** —
  glide down ~13 px over ~1.8 s, instant snap back to the top, repeat identically
  3–4 times.

That waveform is not human input (too metronomic and linear); it is a
self-running animation. Collections and Image Layout are *code-identical* (both a
`Button` + `.moodToolbarIcon` + `.disabled(isSearchActive)`), yet one is stable
and the others drift — so the cause is not a per-icon modifier but something
*positional* (the first trailing item is the layout anchor; the items after it get
repositioned). Grepping for repeating animations found exactly one match:
`GridView.swift` `ShimmerBand` — `withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false))`.
The `1.8 s` linear non-autoreversing curve is a byte-for-byte match for the
measured sawtooth.

**Root cause.** `ShimmerBand` (the loading sheen drawn on every placeholder image
tile while its thumbnail decodes) started its sweep with the **global**
`withAnimation(...)` inside `.onAppear`. `withAnimation` writes the animation onto
the *current transaction*, and `.repeatForever` keeps that animation perpetually
live. When the grid relayouts **while thumbnails are still loading** (column-slider
drag in a search, with placeholder tiles on screen), SwiftUI re-evaluates
`ContentView` and repositions the AppKit-hosted toolbar items in the same update
cycles where shimmer bands are (re)starting their repeat-forever animation — and
sweeps the toolbar items' position changes into that leaked, never-ending 1.8 s
linear animation. The first trailing item (Collections) is the anchor with no
position delta, so it is immune; the items after it drift.

Why it's intermittent and Intel-specific: the leak needs a live shimmer (an
undecoded thumbnail) present *during* a relayout. The tester's 2018 Intel Mac
decodes thumbnails slowly, so shimmers stay alive long enough to overlap a resize,
and the slow relayout spans more update cycles. On faster hardware with warm
thumbnail caches there is usually no active shimmer during a resize, so it doesn't
manifest — which is exactly why it couldn't be reproduced on demand.

**Fix (one file, `Views/GridView.swift`).** Replaced the global `withAnimation` in
`ShimmerBand.onAppear` with a **value-scoped** `.animation(_:value:)` modifier on
the band's Rectangle, keyed on `phase`:

```swift
.animation(reduceMotion ? nil
           : .linear(duration: 1.8).repeatForever(autoreverses: false),
           value: phase)
.onAppear { phase = reduceMotion ? 0 : 1 }
```

`.animation(_:value:)` confines the animation to the band's own subtree and to
changes of `phase`; it never writes to the shared transaction, so the
repeat-forever sweep can no longer bleed into the toolbar (or any sibling view).
The visible sweep is identical (`phase` 0→1, linear, looping). Reduce Motion still
yields a static band (animation `nil`, `phase` left at 0), matching the prior
`guard !reduceMotion` behavior. Per-mount `@State phase` is unchanged — each band
mounts fresh while `thumbnail == nil` and is torn down when the image lands.

**Gotcha recorded.** Never drive a perpetual animation with a global
`withAnimation(....repeatForever(...))` in `.onAppear`. The repeat-forever
transaction stays live and leaks into any view repositioned in the same update
cycle — most visibly the AppKit-hosted window toolbar. Use the value-scoped
`.animation(_:value:)` modifier so the repeat is confined to its own subtree.

**Verification.** Debug build green; full test suite green (all `MuseTests` +
UI tests passed, 0 failures). An independent review confirmed the SwiftUI
semantics (scoped repeat-forever, leak elimination, Reduce-Motion parity, clean
per-mount state) with no regressions. The live glitch itself could not be
re-observed on the development machine (warm caches → no shimmer active during a
resize); the on-device way to confirm is to clear the thumbnail cache or open a
fresh folder, then drag the column slider while tiles are still shimmering.

---

### Extensionless image classification — 2026-06-19 (on `feat/next-27`)

**Symptom.** In a cross-folder tag view the user hit a tile rendered as a generic
"?" document card (folded-corner doc icon) with a very long filename caption.
Clicking it didn't open the hero viewer — it opened a bare modal: a title strip
with the long filename at the very top and the same "?" placeholder in a white
box, no tags, no info column, no Reveal-in-Finder. A second file behaved the same.

**Investigation.** Screenshot 1 was not the hero at all — it's the `ViewerChrome`
+ `QuickLookFallback` path used for **non-image** kinds (title capsule at top +
QuickLook preview, which for an unpreviewable file shows the "?" placeholder).
Screenshot 2 was the grid's **file-card** rendering (icon + filename caption),
also a non-image path. So the real question was why an apparent image was treated
as a non-image.

The long caption text wasn't in the DB (`paths`/`caption` both missed — the
"Knight"/"Candy" hits were a false positive on a different typeface file).
Spotlight (`mdfind`) found the file in the iCloud `Saved Inspo` folder. Its name
is the **entire Instagram alt-text** — **254 bytes**, right at the APFS 255-byte
filename limit — and the `.jpg` extension had been **truncated off** at save time;
the name now ends `…BROOK…` with no extension. `file` confirmed it's a real JPEG
(420×525); `mdls` reported `kMDItemContentType = public.data`,
`kMDItemKind = "Document"` (Finder shows the same generic doc icon). A Swift probe
nailed it:

```
pathExtension  = ''                 ← Foundation finds no extension (trailing " BROOK…" isn't a valid one)
contentType    = public.data        ← OS calls it generic data, conforms .image = false
ImageIO type   = public.jpeg        ← but the bytes ARE a JPEG
```

**Root cause.** `AssetKind.classify` → `classifyByUTType` resolved the file's type
via `url.resourceValues(.contentTypeKey)`, which returns `public.data` for an
extensionless file. `public.data` conforms to none of the handled categories, so
it returned the `.unknown` fallback. The file's header doc-comment *claimed*
"content sniffing (UTType / magic bytes)" but the code never actually read the
bytes. So a valid image that lost its extension was permanently misclassified —
file-card in the grid, `ViewerChrome` fallback on open.

**Decision — don't rename the file.** Adding the extension back would mean
renaming the user's file on disk, which violates the "never modify user data"
rule (and risks iCloud/Finder reference breakage). The fix makes Muse *robust to*
these files instead.

**Fix (TDD, `Models/AssetKind.swift`).** When neither the extension nor the OS
content-type names a handled kind, fall back to a real ImageIO header sniff
(`CGImageSourceCreateWithURL` → `CGImageSourceGetType`) and map the result. An
image whose extension was truncated off, or saved with an unrecognized extension
(Twitter's `.jpg_large`, a bare `.dat`), now classifies as `.image`. Refactor
split the conformance ladder into a reusable `mapped(from:)` (order preserved
verbatim: raw → image → pdf → movie → audio → sourceCode → plainText → archive →
font), so all previously-recognized types are byte-for-byte unchanged — the sniff
is strictly a last resort on the otherwise-`.unknown` branch.

**One change fixes both surfaces.** `ThumbnailCache.generate` also calls
`AssetKind.detect` and routes `.image`/`.raw`/`.psd` through ImageIO
(`imageIOThumbnail`), which decodes the extensionless JPEG fine — so the grid tile
becomes a real full-bleed image thumbnail. And `ViewerRouter` sends `.image` to
the real `HeroImageViewer` (info column, tags, Share/Open-With/Reveal). No
ThumbnailCache or ViewerRouter edit needed.

**Review-driven hardening (two independent review rounds).**
- **Dataless iCloud guard.** The sniff reads bytes; on a not-yet-downloaded
  iCloud placeholder that would force a download just to classify a file the user
  is browsing past — contradicting the app's "skip dataless on index/enumerate"
  rule (the buggy file lives in iCloud). `typeFromImageContent` now short-circuits
  via `isDataless(url)` (`.ubiquitousItemDownloadingStatusKey == .notDownloaded`),
  mirroring `Indexer.isDataless`; a dataless file stays `fallback` until local,
  then re-enumeration reclassifies it. Recorded as a durable gotcha.
- **Scope made intentional.** The sniff also runs for unrecognized **non-empty**
  extensions (not just empty) — kept deliberately (covers `.jpg_large` web saves),
  documented in the code, and tested both ways. An extension allow-list was
  rejected as fragile (would silently miss the next odd truncation). Cost is a
  header-only read on the rare unmatched branch; a recognized extension hits
  `byExtension` and never reaches it, so normal folders pay nothing.

**Availability.** `CGImageSource*` (ImageIO, since macOS 10.x) and `UTType(_:)`
(macOS 11+) are well below the 14.6 minimum, so this works across the full
supported range including Sequoia.

**Tests.** New `MuseTests/AssetKindTests.swift` (7 cases): extensionless JPEG/PNG
→ `.image`; the real truncated-Instagram name shape (asserts empty `pathExtension`
precondition) → `.image`; normal `.jpg` still `.image`; extensionless non-image
→ `.unknown`; unrecognized-extension image (`.jpg_large`) → `.image`;
unrecognized-extension non-image → `.unknown`. Each image case reliably fails
pre-fix (`public.data` → `.unknown`).

**Verification.** Watched the RED (3 extensionless-image cases failing) → GREEN.
Full suite green: 260 tests, 0 failures (`** TEST SUCCEEDED **`), clean build.
Two adversarial review rounds: all should-fix items resolved, no correctness
regressions; remaining notes were LOW-perf/informational and consciously
accepted. User's file left untouched on disk.

### Collection "shows N but opens empty" — count-vs-contents fix — 2026-06-19 (on `feat/next-28`)

**Symptom.** A collection's card/header showed a member count (e.g. "Shopping
15") but opening it landed on an empty/partial grid. Transient and self-healing
(by the time the user re-checked, all 15 were present and every card had
thumbnails). **NOT** the old ghost-row bug (`PathReconciler` already fixes
deleted-from-disk rows): every member existed on disk and was fully downloaded.
Full investigation + plan in
`docs/superpowers/specs/2026-06-19-collection-count-vs-contents-mismatch-design.md`.

**Root cause — a count-vs-contents source split.** The badge and the opened grid
read different sources at different times:
- **Badge** = `CollectionsRow` → `CollectionStore.fetchAll`'s `aliveCount`, a pure
  `is_alive=1` DB count served from `CollectionsEngine.collections` (an in-memory
  snapshot refreshed only on `reload()`).
- **Grid** = `AppState+Filters.setActiveCollection` → live `alivePaths` →
  `fileExists` filter → sort.

So a stale snapshot (or any disagreement) reads as "15 over empty." Two genuinely
wrong details fed it: (1) `/Users/…/Downloads/social.jpg` was an alive member
**outside every added root** — the badge counted it (DB-only) but the sandbox can
never display a file outside its roots, a permanent phantom; (2) the leading
theory for the transient churn is that a post-update cold launch enumerates an
iCloud folder **partially**, dropping not-yet-materialized files from `is_alive`
until a later complete pass restores them (the badge "15" then being a stale
pre-flip snapshot).

**Lever 1 — unify the count onto a live, reachability-aware source (shipped, TDD).**
`CollectionStore.fetchAll` gained a `rootPaths: [String] = []` parameter and now
counts alive member **paths** (matching the grid's per-path display) narrowed to
those **under an active root** via a new pure `CollectionStore.isUnderAnyRoot`
(prefix rule, no disk access: a root or its descendants, rejecting sibling
prefixes like `…/Inspo Extra`). Empty `rootPaths` (before AppState has pushed the
roots) falls back to the plain alive count so nothing zeroes out. `CollectionsEngine`
holds the active root paths (`setRoots(_:)`, re-counts on change) and passes them
into `fetchAll`; `AppState.rebuildRootNodes` pushes `rootNodes.map(\.url)` into the
engine alongside the existing `folderStats.update`. **The grid side was unified to
the SAME rule** (review round 1): `AppState+Filters.setActiveCollection` now filters
the collection's `alivePaths` through `isUnderAnyRoot` (against the standardized
`rootNodes` paths, same empty-roots fallback) BEFORE the `fileExists` node build, so
an out-of-root member can't appear in the grid either. Net: badge and grid share
one predicate — the badge can never claim a number the grid can't back up (during
churn both drop together, then return to 15 — an honest, self-healing number), and
the out-of-root Downloads phantom counts in neither. Grid ≤ badge by construction
(grid additionally requires `fileExists`); the remaining gap (an under-root file
that's transiently dataless) is exactly the Lever 2 case. The count also switched
from `COUNT(DISTINCT file_id)` to a per-PATH count (`DISTINCT absolute_path`) so a
byte-exact duplicate that the grid renders as N tiles counts as N, not 1; the
`paths(absolute_path) WHERE is_alive=1` partial unique index guarantees the count's
path set and the grid's `alivePaths` set are identical. New
`MuseTests/CollectionCountReachabilityTests.swift` (8 cases: the pure rule incl.
sibling-prefix/empty-roots/long-iCloud-path, out-of-root excluded, empty-roots
fallback, all-out-of-root auto collection dropping from `fetchAll`, and the
duplicate-path per-path count). Existing `fetchAll(queue:)` callers/tests are
unaffected (defaulted param → fallback path). Two independent review rounds: round
1 found the badge/grid rule divergence (fixed) + asked for the duplicate-path test
(added); round 2 verified the fixes and returned clean.

**Lever 2 — diagnostic only; hardening deliberately deferred.** The spec's Plan
step 0 gates the data-loss-sensitive `PathReconciler` change on a confirmed
trigger ("do not guess and harden the wrong thing"), which needs a live
post-update cold-launch repro. Added ONE diagnostic `print("[PathReconciler] …")`
in `reconcile` that logs the folder, how many rows the pass would flip, the
`present` count, and a few sample filenames whenever it marks rows dead — so the
user can reproduce and confirm it's the Saved Inspo iCloud files being dropped on
a partial enumeration. The partial-materialization guard (extending the existing
fully-empty `trustworthy` probe in `AppState` to the partial case) is **not**
implemented yet — a blind version risks reintroducing the very iCloud ghost-row
bug `PathReconciler` exists to fix. Pick up there once the log confirms the
trigger.

**Verification.** Watched RED (new tests fail to compile — `isUnderAnyRoot` /
`rootPaths` missing) → GREEN. Full `MuseTests` suite green (**261 tests**, 0
failures, `** TEST SUCCEEDED **`) after the review-round fixes. Files touched:
`CollectionStore.swift`, `CollectionsEngine.swift`, `AppState.swift` (setRoots
push), `AppState+Filters.swift` (grid reachability filter), `PathReconciler.swift`
(diagnostic), + the new test file.

### Collections page scroll-clip — no-tags cutoff made universal — 2026-06-19 (on `feat/next-29`)

**Symptom.** On the dedicated Collections **card page**, scrolling up let the
cards slide *under* the floating window toolbar / search bar, instead of being
cut off at the toolbar edge the way the main grid is. The grid had this exact
problem fixed earlier (the "no-tags top inset" fix, `ff30f47`); the card page
never got the same treatment.

**Root cause — a missing top reserve, not a missing clip.** A SwiftUI
`ScrollView` clips its content to its own frame. The main grid lives in
`ContentView`'s `VStack(spacing: 0) { TagChipsRow(); GridView() }`, and
`TagChipsRow`'s no-tags branch reserves a `Color.clear.frame(height: 10)` ABOVE
the grid's scroll view — so the grid's clip boundary sits 10pt below the toolbar
and content is cut off there. `CollectionsPage` is the *other* `ContentView`
branch (`isCollectionsPage`), a standalone view whose `ScrollView` filled the
whole detail pane right up to the toolbar edge — no reserve, so its clip boundary
was at y=0 and cards bled up under the transparent toolbar (`.toolbarBackground(.hidden)`).
The in-collection view was never affected: it uses `GridView` + `TagChipsRow`, so
it already inherits the reserve.

**Fix.** Wrap `CollectionsPage`'s body in `VStack(spacing: 0)` with the same
`Color.clear` reserve above the `GeometryReader`/`ScrollView`, and move
`.background(moodPalette.background)` onto the `VStack` so the reserve strip is
painted too. The `GeometryReader`'s card-width math is unaffected (the spacer
only steals vertical space); `PageScrollCatcher` still resolves
`enclosingScrollView` through the AppKit chain (SwiftUI wrappers don't insert
scroll views). Bonus: the "Collections" title now lands at the same 10 + 14 = 24pt
offset as the in-collection header (`CollectionsRow`'s `.padding(.top, 14)` under
the same reserve) — previously misaligned by 10pt.

**Drift guard (review nit, addressed).** The two reserves MUST stay equal for the
cutoff to match, so the magic `10` was extracted to one constant —
`TagChipsRow.noTagsTopClearance` — referenced by both the no-tags branch and
`CollectionsPage`. An independent review of round 1 returned **ship**; this was
its only (non-blocking) finding.

**Durable gotcha.** A `ScrollView` clips to its own frame — to make scrolled
content cut off below the floating toolbar (rather than slide under it), reserve
the toolbar clearance ABOVE the scroll view, not as inner content padding (which
scrolls away with the content). Every top-level scroll surface needs its own
reserve; they're independent views. Keep the two reserves on the shared
`TagChipsRow.noTagsTopClearance` constant.

**Verification.** Build green; full `MuseTests`/UI suite green (`** TEST SUCCEEDED **`,
0 failures) before and after the constant extraction. Launched the Debug build,
navigated to the Collections page, confirmed the title clearance + card grid.
Files touched: `CollectionsPage.swift`, `TagChipsRow.swift` (the shared constant).
No test — a pure SwiftUI layout change (UI views aren't unit-tested).

### Escape backs out of a collection / the Collections page — 2026-06-19 (on `feat/next-30`)

**Ask.** Let the Escape key back out of an open collection and the Collections
page, as a keyboard accelerator alongside the visible back buttons — "if you
don't want to press the back button." Confirmed it's an accepted macOS pattern
(Escape = dismiss/cancel/pop the current focused context); shipped as *additive*
to the back buttons, not a replacement.

**Priority chain (innermost-first), via a pure resolver.** Escape peels exactly
one layer per press: (1) hero image viewer → its return flight; (2) other viewer
(PDF/video/…) → dismiss; (3) active/typed search → clear it; (4) inside a
collection → pop to the Collections page; (5) on the Collections page → return to
the grid; (6) plain grid → nothing. All decision logic lives in a pure
`EscapeResolver`/`EscapeAction` (`Components/EscapeAction.swift`), mirroring the
repo's tested-helper convention (`GridSelection`, `PageScroll`, `CollectionSort`,
`DuplicateDeleteRules`). `ContentView`'s existing hidden `keyboardShortcut(.escape)`
Button is now a thin mapper onto the SAME calls the visible back buttons make:
`.exitCollection` → `setActiveCollection(nil)` (the in-collection `BackArrowButton`),
`.exitCollectionsPage` → `toggleCollectionsPage()` (the Collections-page back arrow).

**Hero-close path untouched (the load-bearing constraint).** Any selected file
short-circuits to `.closeHero`/`.closeViewer` BEFORE any back-out case, so the
new chain can never interleave with the delicate hero close — the `.closeHero`
case still fires ONLY `viewerClosing = true` and lets `startClose()` own the rest,
exactly as the 2026-06-18 two-press fix requires. A test
(`testHeroOpenInsideCollectionStillClosesHero`) locks this even with search +
collection + page all set.

**QA finding folded in — search sits ABOVE the collection back-out.** `runSearch`
does NOT clear `activeCollectionID`/`showingCollections` (a search just overrides
what the grid shows), so you can search *inside* a collection. Peeling the search
first (`.clearSearch` → `AppState.clearSearch()`, which leaves collection state
intact) returns you to the collection's own members via `visibleFiles`'
`activeCollectionFiles ?? currentFiles` fallback — rather than silently dropping
the collection while results still show (a dead key). "Search present" =
`isSearchActive || !searchQuery.isEmpty` (mirrors `selectFolder`'s teardown
check), extracted to a tested `EscapeResolver.searchPresent(...)` so the glue
isn't an untested boolean.

**Modals are a non-issue.** macOS SwiftUI `.sheet`/`.alert`/`.popover` present in
separate key windows, so the parent window's `keyboardShortcut(.escape)` Button
doesn't fire while one is up; the sheets that need Escape carry their own
`.cancelAction` and the mood popover is AppKit-dismissed. An independent code
review confirmed this reasoning and returned **ship** with no Critical/Important
findings (two Minor polish items — the `searchPresent` test and a doc note —
were both folded in).

**Verification.** TDD throughout (watched each test fail, then pass). New
`MuseTests/EscapeActionTests.swift` (12 cases: viewer priority, search-before-
collection ordering, the back-out chain, the `searchPresent` glue). Build +
full suite green (`** TEST SUCCEEDED **`, 0 failures). Files touched:
`Components/EscapeAction.swift` (new), `ContentView.swift`,
`MuseTests/EscapeActionTests.swift` (new).

### Image Layout modal tiles are mood-adaptive — 2026-06-19 (on `feat/next-31`)

**Ask.** The 9 grey layout-selection tiles in the Image Layout modal looked a
little dark. First pass just lightened the fixed grey — but on a Dark (or Custom)
mood the modal chrome already flips to dark (the sheet inherits
`preferredColorScheme(moodPalette.scheme)` from `ContentView`), while the tiles
stayed a fixed light-grey card with black text. They read as glaring white cards
on a dark sheet, and the labels would have needed re-contrasting too. The ask
became: make the tiles auto-adapt to the mood like the Info modal does, via an
inline override (no new type, no change to the global palette).

**Why they weren't adaptive.** The tiles were wired to `Mood.paperPalette.tileFill`
— a *fixed* light-mode grey. That was deliberate in feat/next-22 ("mood-independent
layout modal"). The Info modal (`InfoSheet`) adapts for free because it hard-codes
no colors at all — just `.primary`/`.secondary` over the forced color scheme.

**Fix.** `LayoutTile` now takes the active `MoodPalette` (`appState.moodPalette`)
instead of a `Color`, and derives everything from it:
- **Surface** — `Color(white: isDark ? 0.24 : 0.95)`. An elevated card in either
  scheme: light mode lands at the lighter grey requested; dark mode lifts *above*
  the dark sheet so the tile still reads as a card (the mood's own `tileFill` of
  0.118 would have sat darker than the sheet). Kept neutral rather than the colored
  custom-mood tile so the cards stay legible on a colored background.
- **Label + icon** — `MoodPalette.iconColor` (black-on-light / white-on-dark), the
  same value the toolbar icons use, so text auto-contrasts.
- **Hover veil** — flips: a dark wash on light tiles, a light wash on dark tiles
  (with a lower opacity in dark, 0.10 vs 0.20).
- **Animation** — `.animation(.easeInOut(duration: 0.35), value: palette)`, the
  same curve/duration the background fade uses, so the tiles crossfade in lockstep
  with the mood change exactly like the toolbar icons (feat/next-24).

Selection blue fill + ring are unchanged (system accent, not mood). This reverses
the "mood-independent" decision from feat/next-22 by explicit request; the
CLAUDE.md architecture-map note for `ImageLayoutSheet.swift` was updated to match.

**Verification.** Build + full suite green (260 tests, `** TEST SUCCEEDED **`). No
new test — a pure SwiftUI cosmetic change (UI views aren't unit-tested, and Color
equality is unreliable, same call made for feat/next-24). Diff review (all angles,
manual given the 38-line single-file scope) returned clean. One file:
`Views/ImageLayoutSheet.swift`.

### Collections in the Sidebar (opt-in) — 2026-06-19 (on `feat/next-32`)

**Ask.** Surface collections in the left sidebar, beneath the folders, gated by a
new Preferences toggle **"Show Collections in the Sidebar"** (default OFF = the
current folders-only sidebar, unchanged). ON: a gray **FOLDERS** header and a gray
**COLLECTIONS** header, each with the hero viewer's circular collapse button
(`+` collapsed → 45°-rotated `×` expanded, same spring motion/hover). Under
COLLECTIONS, the collections list — each row a `square.stack.3d.up` icon + name +
image count — with the same affordances as the folders above: an independent
sort (incl. Manual drag-reorder), right-click Delete/Rename/Move Up-Down, app-menu
reach, and full accessibility. Plus a bottom bar that becomes two pills
(Add Folder + Add Collection). Mockups provided.

**Decisions locked in brainstorming.**
- The sidebar's order + sort are **completely independent** of the Collections
  *page*. Even picking Name / Date Created in the sidebar must not touch the page,
  and dragging in Manual writes a sidebar-only order. (Mirrors how the sidebar
  folder sort is independent of the grid sort.)
- Sort modes = the page's three (Name / Date Created / Date Modified) **plus
  Manual** (Manual is what enables drag + Move Up/Down). No Size (no per-collection
  size). The +/× header button is collapse-only, NOT a create button.
- Creation in the sidebar is the new bottom **+ stack** pill → the existing Name
  Collection modal; new collections land at the bottom of Manual.

**Build (spec + plan → TDD).**
- New pure `Models/SidebarCollectionSortMode.swift` — enum + `SidebarCollectionSort.order`
  (Manual by `sort_order`, Name A→Z, dates newest-first, name tiebreaks),
  unit-tested. Mirrors `FolderSort`/`CollectionSort`.
- Migration **v8_collection_sort_order**: `collections.sort_order INTEGER NOT NULL
  DEFAULT 0`, with a deterministic `nonisolated static Database.backfillCollectionSortOrder`
  (order by `created_at`, then `name`). `CollectionRow.sort_order` (default 0 so
  existing memberwise constructions still compile). `CollectionStore.nextSortOrder`
  (`max+1`) is applied in BOTH `createManual` overloads and in `upsert` (the
  ON-CONFLICT path deliberately leaves `sort_order` untouched so a user's manual
  arrangement survives reclustering). `CollectionStore.persistOrder(orderedIDs:)`
  writes `sort_order = index` in one transaction. Two store/migration test files.
- `AppState.sidebarCollectionSortMode` (@Published, persisted via `didSet` like
  `imageLayout`); `AppState.sidebarCollections` (the engine's visible collections
  re-ordered by the sidebar mode); `moveSidebarCollection(id:by:)` (Manual
  Move Up/Down) + `reorderSidebarCollections(_:)` (persist + reload).
- `Settings`: the toggle (new "Sidebar" section) + the two AppSettings accessors.
- `SidebarView` restructure: `folderList` extracted and shared; OFF →
  `foldersScroll` (the original); ON → `twoSectionScroll` holding both sections in
  ONE `ScrollView` (collapsible `SectionHeader`s, the folder reorder overlays AND a
  parallel set of collection reorder overlays). New `CollectionSidebarRow`
  (icon/name/count, click-to-activate, blue selection when `activeCollectionID ==
  id && !showingCollections`, context menu, full a11y), a flat-list collection
  reorder (its own drag state + `CollectionFramePreference`, mirroring the root
  reorder math/overlay), `collectionsSortHeader`, and a `bottomBar` that swaps the
  single pill for two compact `AddPillButton`s. `SectionHeader` reuses the hero
  `PlusCircleButton` shape tuned for the light sidebar (secondary glyph on a faint
  `Color.primary` circle).
- `MuseApp`: **Move Collection Up/Down** added to the Collections command menu,
  gated on `showCollectionsInSidebar` + Manual + an active collection (the active
  collection is the move target).

**Why a flat-list reorder mirror, not a shared engine.** The root reorder
machinery is tied to `Root`/`FolderNode` with hierarchy, the iCloud home, stars,
and expandable children. Collections are a flat list of `CollectionStore.Loaded`
keyed by string id, so a parallel (simpler) copy of the same live-drag pattern —
hidden source row + opaque floating overlay (LazyVStack ignores zIndex) + parting
offsets + insertion line, all in the shared `reorderSpace` — was cleaner than
generalizing the folder code. Move Up/Down + `persistOrder` guarantee correctness
even if the in-flight visuals degrade on a long scrolled list (same caveat the
folder reorder documents).

**Verification.** Full app build `** BUILD SUCCEEDED **`; full suite
`** TEST SUCCEEDED **` — 280 unit cases (incl. the 7 new) + the 4 UI tests, 0
failures. Note: `xcodebuild -scheme Muse test` runs MuseTests via the streaming
XCTest format ("… passed on 'My Mac - Muse (pid)'"), so it has no per-bundle
"Executed N tests" line — only the legacy MuseUITests bundle prints that;
`-only-testing:MuseTests` (bundle granularity) matches nothing under the
auto-generated scheme, so verify with the plain `test` action or class-level
`-only-testing`. The Collections page is untouched. Spec + plan in
`docs/superpowers/`.

**QA iteration (live testing in the running app).** Several rounds of tester
feedback on the running build, each fixed and rebuilt:

- **Settings → in-app modal.** The tester wanted Settings to look like the other
  modals (dimmed tint, centered) rather than the native Preferences window. The
  `Settings {}` scene was removed; `CommandGroup(replacing: .appSettings)` now opens
  a `.sheet` bound to `AppState.settingsShown` (⌘, preserved). `SettingsView` gained
  a `@Binding isPresented` + header + `SheetCloseButton` (the InfoSheet chrome), and
  is sized to content (`.frame(width: 600).fixedSize(vertical:)`) so every section
  shows without a tall empty sheet.
- **Section collapse felt instant, +/× didn't spin.** Root cause: the collapse flags
  were `@AppStorage`, and a `withAnimation` transaction doesn't carry into a
  UserDefaults publish. Switched them to plain `@State` seeded from / persisted to
  `UserDefaults` (via `.onChange`); the `SectionHeader` toggle is now wrapped in
  `withAnimation(.spring…)`, so the spin AND the content show/hide animate together
  like the hero modal.
- **Collection rows sat too far left / didn't line up with folders, and the grip +
  right-click Move/Rename "weren't there."** `CollectionSidebarRow` had diverged
  structurally from the proven `FolderTreeNode` row. Reworked it to mirror the folder
  row exactly: a leading invisible chevron-width spacer, icon `frame(width: 18)`,
  `.padding(.horizontal, 6)`, the tap on the inner content with hover + context menu
  on the outer. Icons/text now align with the folders, and the grip-on-hover +
  Rename/Delete/Move-Up/Down menu behave like folders.
- **Dropping a dragged collection flashed** — the row visibly caught up a frame
  late. `reorderSidebarCollections` was doing an async DB write + engine reload, so
  the commit's non-animated transaction cleared the lift offset BEFORE the new order
  arrived. Fixed by applying the new order to the in-memory
  `CollectionsEngine.collections` `sort_order` SYNCHRONOUSLY (then persisting async,
  dropping the reload) — exactly how the folder reorder leans on `bookmarks.$roots`
  delivering synchronously. (Recorded as a durable gotcha.)
- **Changing the sort dropdown flew rows in from above** instead of reordering in
  place. The collections list was a `LazyVStack` over `Array(enumerated())`; SwiftUI
  treated the reorder as insert/remove and flew the rows. Switched to a NON-lazy
  `VStack` iterated directly by `collection.id`, with a list-scoped
  `.animation(.easeInOut, value: sidebarCollectionSortMode)` (and dropped the global
  `withAnimation`, which had animated the surrounding VStack). Rows now move in place
  like folders. (Also a durable gotcha.)
- **Sidebar didn't highlight the collection you were in** when you opened it from a
  card on the Collections page. `isSelected` had a `&& !showingCollections` guard
  that suppressed the highlight there. Dropped it — `isSelected` is now just
  `activeCollectionID == id`, so the active collection highlights regardless of entry
  path (folders stay de-highlighted while a collection is active, so no clash).
- **Move Up/Down parity:** wrapped the menu/keyboard `moveSidebarCollection` reorder
  in `withAnimation` so it slides like the drag (the in-memory reorder is synchronous,
  so it animates cleanly) — an independent code-review Minor.

After the QA round: full app build green, full suite green (280 unit cases + 4 UI,
0 failures), independent code review clean (no Critical/Important). The default
(setting OFF) sidebar is byte-for-byte the original, and the Add Folder pill stays
pinned below the scroll in both states.

### Collections-page card restyle — 2026-06-19 (on `feat/next-33`)

**Ask.** Visual-only cleanup of the Collections-page cards (`CollectionCard` in
`Views/CollectionsRow.swift`), iterated live with the user:

- **Dropped the resting chrome** — removed the soft drop shadow
  (`.shadow(black 0.09, r4, y1.5)`) and the fixed hairline grey border
  (`Color.primary.opacity(0.12)`) the cards carried, so a card no longer reads as
  a lifted object.
- **Corner radius 10 → 8** on all four `RoundedRectangle`s (cover clip + the three
  overlays) so the card corners match the main grid's selection ring
  (`GridView.ringCornerRadius = 8`); all stay `style: .continuous`.
- **Re-added the outline as mood-adaptive ("Auto")** — instead of a fixed grey, the
  hairline is `appState.moodPalette.iconColor.opacity(0.05)` (black on light moods,
  white on dark), paired with
  `.animation(.easeInOut(duration: 0.35), value: appState.moodPalette)` so it
  crossfades in lockstep with the background fade, exactly like the toolbar icons
  (feat/next-24) and the Image Layout tiles (feat/next-31). The `0.05` opacity is a
  per-overlay local value — `iconColor` itself is untouched, so nothing else in the
  app changes. (Landed at `0.05` after live tuning: 0.12 → 0.2 → 0.08 → 0.04 →
  0.05.) The mood `.animation(value:)` is placed ABOVE the hover-veil and active-
  accent overlays so only the outline follows the mood; the veil keeps its own
  `.animation(value: hovering)` and the active accent border (system accent,
  lineWidth 2) is unchanged.

**Verification.** Build + full suite green (`** TEST SUCCEEDED **`). No new test —
a pure SwiftUI cosmetic change (UI views aren't unit-tested; Color equality is
unreliable, same call as feat/next-24/next-31). One file:
`Views/CollectionsRow.swift`.
