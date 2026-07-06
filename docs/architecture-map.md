# Muse — architecture map

Current-state file index for the Muse app. For the "why it changed" history
behind any piece, read the matching entry in `session-log.md`. The load-bearing
must-not-break rules are in `../CLAUDE.md` → Durable constraints & gotchas.

```
Muse/Muse/
  MuseApp.swift                    entry point; launch tasks (ThumbnailCache LRU
                                   prune, 180-day Housekeeping prune, IntentBackfill);
                                   owns the Sparkle updater + "Check for Updates…";
                                   `AppDelegate` backs the standard Edit ▸ Select All
                                   (responder-chain `selectAll(_:)` → selectAllVisible)
  Updates/
    Updater.swift                  Sparkle SPUStandardUpdaterController wrapper +
                                   CheckForUpdatesView. Direct-distribution self-
                                   update; see docs/RELEASING.md
  ContentView.swift                NavigationSplitView shell; floating tag chips;
                                   toolbar; menu-bar Tags/Collections
  Models/
    AppState.swift                 @MainActor singleton — roots, active folder,
                                   current files, selected file, sort mode + direction,
                                   search, mood, watcher, indexing. Holds the stored
                                   @Published state; method clusters split into the
                                   AppState+* extensions below (stored props CANNOT
                                   move to an extension, so they all stay here).
                                   Memoized visibleFiles; owns tag-chip data
                                   (tagChipRows), folderStats, folderSortMode,
                                   collectionSortMode/Reversed, tileBackground (+
                                   effectiveTileBackground/tileFill), gridFilter.
                                   openSubfolder/resolveFolderNode navigate folder cards
    AppState+Selection.swift       grid MULTI-selection (selectedFiles: Set<String> +
                                   anchor): applyClick / clearSelection /
                                   selectAllVisible / effectiveSelectionURLs.
                                   pruneSelectionToVisible() drops paths the gridFilter hides
    AppState+Filters.swift         collection + tag-chip filtering: visibleFiles /
                                   tagSourceFiles / setActiveCollection / setActiveTag /
                                   removeTag / toggleCollectionsPage. visibleFiles applies
                                   gridFilter.matches(kind:ext:) as the final narrowing step
    AppState+Backup.swift          backup/restore actions (exportBackup / beginRestorePicker)
    AppState+FolderOps.swift       create/rename subfolder + DB path migration + dialogs
    AppState+Indexing.swift        scheduleIndexing / analyzeCurrentFolder / analyzeSelected /
                                   findDuplicatesInCurrentFolder
    AppState+Search.swift          runSearch / clearSearch
    AppState+Mood.swift            moodPalette / setMood / updateAutoMoodTimer
    AppState+Watcher.swift         startWatching / handleFolderEvent
    AppState+TagChips.swift        reloadTagChips / bumpTagChipToken (also calls
                                   reloadStarRatings — ratings track chips 1:1)
    AppState+Rating.swift          star ratings: reloadStarRatings (per-file badge
                                   map, off-main), setRating(selection), uniformRating
    AppState+Starring.swift        toggleStar / openStarred
    AssetKind.swift                kind enum + extension/UTType detection; classify(url:)
                                   skips detect's fileExists stat. Last-resort ImageIO
                                   header sniff classifies extensionless images; SKIPS
                                   dataless iCloud placeholders (no forced download)
    FileNode.swift                 in-memory enumerated-file value type;
                                   init(url:kind:) takes a precomputed kind. A subfolder
                                   in one-level browse is a `.folder` node — selectable
                                   like a file (filter it from file-only flows)
    FolderOrdering.swift           pure folders-first stable partition for the grid
                                   (Finder pattern); unit-tested
    Root.swift                     security-scoped bookmark wrapper
    DeleteCoordinator.swift        delete state machine (trash + undo toast); drives a
                                   fade-out (internals still named "burn"; shader gone)
    Mood.swift                     Light / Dark / Auto (day↔night) / Custom HSB
    FolderSortMode.swift           sidebar folder sort enum + pure FolderSort.order
                                   comparator (name tiebreak, missing-stat last)
    TagSortMode.swift              tag-chip sort: .count (default) / .alphabetical;
                                   drives TagChipLoader.ordered(_:sortMode:)
    StarRating.swift               pure star-rating helper: a rating is a manual tag
                                   whose label is a run of ★ (U+2605) 1…5. label↔count,
                                   isRating, front-sort, mutual-exclusion resolution.
                                   Unit-tested (StarRatingTests)
    ImageLayout.swift              global grid layout: .masonry (default) + 11 fixed
                                   aspect-ratio cases; exposes aspect/iconKind/resolve.
                                   Unit-tested
    TileBackground.swift           global grid tile BACKDROP: None/Auto(default)/Light/
                                   Dark Grey/Black. backdropRGB/fill resolvers; masonry
                                   forces Auto via AppState.effectiveTileBackground. Unit-tested
    GridFilter.swift               global grid faceted filter (pure, unit-tested).
                                   KindFacet is a flat set of LEAF facets — image FORMATS
                                   (jpeg/png/heic/tiff/gif/webp/raw/psd/svg + imageOther
                                   catch-all) + non-image kinds (video/pdf/document/audio/
                                   folder/other); leaf(kind:ext:) maps each file to one leaf.
                                   "empty == all" sentinel; toggling(_:) + collapse();
                                   imageParentState backs the "Images" tri-state. NO date/
                                   size facets (sort covers them). Persisted JSON; didSet
                                   invalidates the visibleFiles memo + prunes the selection
  Filesystem/
    FileMover.swift                move(_:into:) via FileManager.moveItem; skips name
                                   collisions, returns failures
    FolderOps.swift                pure create/rename folder on disk (sanitize + Result);
                                   no overwrite; allows case-only rename; rejects hidden names
    FolderRenameMigration.swift    folder-rename DB rewrite: pure rule + apply() running
                                   SQL over absolute_path / tags.parent_dir /
                                   starred_folders in one transaction. SQL unit-tested
    BookmarkStore.swift            UserDefaults-backed root bookmarks; sandbox start/stop.
                                   addRoot ACTIVATES before appending so the synchronous
                                   $roots-sink rebuild can resolve the new root (see gotcha)
    FolderTree.swift               lazy hierarchical tree + FolderReader; FolderNode has a
                                   weak parent + reloadChildren(). FolderReader.files(in:
                                   showHidden:includeFolders:) emits subfolders as `.folder`
                                   nodes for the one-level grid; packages stay files
    FolderWatcher.swift            FSEvents-backed live watcher delivering changed paths.
                                   FolderEventFilter (pure) keeps only viewable in-folder
                                   files. watch(urls:) watches many roots at once
    FolderStat.swift               pure FolderStat (immediate+recursive counts, recursive
                                   size + latest mtime); mirrors the grid's file notion.
                                   IMMEDIATE count includes subfolders (matches folder
                                   cards + Finder); recursive count stays files-only
    PathReconciler.swift           pure scope/diff + DB ops marking externally-deleted
                                   files is_alive=0 on fresh folder load (stops ghost rows);
                                   guards evicted iCloud placeholders, markDead chunked at
                                   500. Caller skips reconcile on a false-empty enumeration
    FolderStatCache.swift          @MainActor cache of FolderStat per top-level folder;
                                   off-main compute, live via FSEvents (debounced), set-diff.
                                   Recompute debounce has a maxWait CAP (pure
                                   StatRecomputeScheduler, 0.4s trailing / 2.0s cap) so a
                                   sustained FSEvents stream can't starve it
    StarStore.swift                SQLite-backed starred folders
    ThumbnailCache.swift           QLThumbnail + AVAssetImageGenerator (videos); off-main,
                                   ordered load; 2-tier cache (NSCache 512MB + disk LRU 2GB).
                                   Key on standardized path; invalidate(_:) drops mem+disk so
                                   an in-place edit regenerates. Non-image → QuickLook .all
                                   (real macOS icon/preview)
    AVURLAsset+NoNetwork.swift     `.noNetwork(url:)` helpers pinning every AVFoundation
                                   asset to reference-restrictions .forbidAll — a reference
                                   movie / HLS remote data-ref can't phone home. Use everywhere.
    Sidecar.swift                  portable per-asset metadata value type (Codable);
                                   maps to/from FileRow+TagRow; deterministic merge (manual wins)
    SidecarStore.swift             read/write .muse/<hash>.json with NSFileCoordinator
                                   (no live SQLite in iCloud)
    ICloudZone.swift               discover the single app iCloud Drive folder + membership test
    SidecarHydrator.swift          import current sidecars into local DB on folder load so a
                                   fresh/iCloud-only device skips re-Vision
  Database/
    Database.swift                 GRDB queue + migrations (v1…v8); foreignKeysEnabled
    Records.swift                  FileRow (+analyzed_hash, +intent), PathRow, TagRow, etc.
    SearchService.swift            FTS5 + tag-label search (sidebar-folder scope, path-prefix
                                   guarded). Tag LIKE ORed over SearchBridge terms so a
                                   localized query finds canonical tags
    SearchBridge.swift             pure: expand a query into [raw + canonical] tag-search
                                   terms via VocabularyLocalizer.canonicalize; raw query always
                                   kept. So "plage" finds files tagged "beach". Unit-tested
    TagScope.swift                 parent-folder key derivation — tags are per (file_id,
                                   parent_dir). Single source of truth for migration/TagStore/
                                   AnalyzePipeline
    TagStore.swift                 manual/vision tag CRUD scoped by (file_id, parent_dir);
                                   library-wide rename kept, library-wide DELETE removed
    TagChipLoader.swift            shared query logic for grid tag-chip labels (fast single-
                                   folder GROUP BY + general per-file-scope path). Pure/
                                   nonisolated; AppState owns + calls it. ordered() front-
                                   sorts star-rating chips (highest first)
    RatingLoader.swift             batched per-file star-rating map (path→1…5), same
                                   (file_id,parent_dir) scope + chunked IN as TagChipLoader;
                                   drives the tile badge. TagStore.setRating writes ratings
                                   (mutually exclusive)
    Housekeeping.swift             launch prune: index data unreachable from any sidebar
                                   folder, unseen >180 days
  Localization/                    display-time localization. Storage stays canonical-
                                   English; this layer maps canonical<->localized for
                                   rendering + search. Three removal kill-switches
    VocabularyLocalizer.swift      pure nonisolated seam: display(canonical)->localized
                                   (identity for English/unknown), canonicalize(token)->
                                   canonical?. static shared honors the per-app language
                                   override. Unit-tested
    VisionVocabulary.json          bundled {canonical:{lang:term}} table; FULL fr (all 1303
                                   VNClassifyImageRequest taxonomy terms)
  Localizable.xcstrings            (at Muse/Muse/ root) UI-chrome String Catalog; FULL fr
                                   (371 strings). NOTE: a plain xcodebuild build does NOT
                                   write extracted keys back — use `xcodebuild
                                   -exportLocalizations`, then translate
  Indexing/
    HashService.swift              streaming SHA-256; nil on dataless iCloud reads
    Indexer.swift                  identity reconciliation matrix (§4); size+mtime fast path;
                                   skips not-downloaded iCloud items. reconcile/indexFile/
                                   indexBatch report content-changed (re-hash for edits + iCloud verify)
  Intelligence/
    Vision/
      VisionServices.swift         classify/OCR/faces/feature print/dom color + CaptionBuilder
                                   (Vision-derived, NOT LLM)
    Sort/
      SmartSorter.swift            7 sort modes; Color + Shape pull FileRow data
    Dedup/
      DuplicateFinder.swift        byte-exact + visual + filename clusterers; smart-suggest
                                   only where signal is strong
      DuplicateDeleteRules.swift   pure delete-selection rules for the Duplicates modal:
                                   seed / rescued / isLocked / selecting. A group is never
                                   fully deleted; a file in several groups is checked against
                                   ALL of them; single 2-copy group swaps. Unit-tested
    Core/
      PaletteExtractor.swift       k-means palette (RGBA-redraw)
      CollectionNaming.swift       Foundation Models namer (gated) → tag fallback
      IntentBucket.swift           10 screenshot-intent buckets: keys, display names, stable
                                   collection ids, raw→bucket, color
      IntentClassifier.swift       pure IntentInput helpers + FM-gated classifier
    Collections/
      CollectionsEngine.swift      two-track recluster: intent collections + emergent
      IntentCollections.swift      pure: which intent buckets qualify (≥3 members)
      CollectionSort.swift         pure Collections-page ordering (Name/Date Created/Date
                                   Modified + reverse); unit-tested
    AnalyzePipeline.swift          AUTOMATIC after indexing — analyzes only stale
                                   analyzed_hash files; writes FileRow, tags, FTS5; classifies
                                   intent (gated). Passes serialize via acquirePass()/passClaimed
    IntentBackfill.swift           one-time launch pass: classify pre-existing screenshots from
                                   stored OCR (no re-Vision)
  Agents/
    AppIntents/
      MuseAppIntents.swift         OpenFolder/FindDuplicates/AnalyzeFolder/SearchLibrary intents
                                   + AppShortcutsProvider
  Viewers/
    PDFViewerView.swift            PDFKit, view-only
    TextViewerView.swift           NSTextView wrapper, isCode/isRTF flags
    MarkdownViewerView.swift       AttributedString markdown
    SVGViewerView.swift            WKWebView, file:// only (no network)
    VideoPlayerView.swift          AVKit AVPlayerView; .resizeAspect + clear layer bg (no black
                                   bars over the hero backdrop). Pauses+nils on unmount.
                                   Used only by HeroVideoViewer
    AudioPlayerView.swift          AVKit + asset metadata
    ModelViewerView.swift          SCNScene from URL
    FontViewerView.swift           process-scope font registration (unregisters on teardown)
    ViewerChrome.swift             dimmed bg + close button + Esc dismiss (all non-image/video kinds)
    HeroPalette.swift              shared on-open palette for the hero viewers: pure nonisolated
                                   paletteHexes(fromRGBA:…) + quickPalette(images, ImageIO) +
                                   videoPalette(one AVAssetImageGenerator frame). Unit-tested
    FileMetadata.swift             hero INFO-card metadata: pure formatting (EXIF/TIFF/GPS ·
                                   PDF doc attrs · video Recorded/Dimensions/Duration/FrameRate/
                                   GPS · A/V duration · Modified date) + off-main loader
                                   load(url:kind:). Read on viewer-open only (no DB/migration);
                                   dataless iCloud guard. Value types are `nonisolated`. Unit-tested
  Views/
    Sidebar/                       sidebar row + support views split out of SidebarView:
                                   FolderTreeNode (folder row), CollectionSidebarRow (collection
                                   row), SidebarRows (StarRow/AddFolderPillButton/SectionHeader/
                                   AddPillButton), SidebarReorderSupport (frame prefs + reorder env)
    SidebarView.swift              multi-root OutlineGroup tree + starred section; file-URL drop
                                   on folder rows MOVES the selection there (folders filtered out).
                                   Row isSelected matches by standardized URL; no folder shows
                                   selected in cross-folder views. Top-level reorder is a LIVE
                                   DragGesture off a trailing grip (NOT .onDrag). "Sort:" header
                                   orders top-level folders; Manual is draggable + has live counts.
                                   Right-click / Edit-menu Move Up/Down is the keyboard parallel
    GridView.swift                 VIRTUALIZED masonry grid — precomputes tile frames
                                   (MasonryGeometry from AspectRatioCache), renders only viewport
                                   tiles (+overscan); column slider; tiles fade in as thumbs land.
                                   The ONLY grid view. Click = select (Cmd toggles, Shift ranges),
                                   double-click opens (timed from the event's hardware timestamp);
                                   .onDrag carries the URL; selection-aware contextMenu. A `.folder`
                                   tile selects like a file but double-click NAVIGATES
                                   (openSubfolder); folder Move-to-Trash skips folder nodes.
                                   Non-image tiles render the native macOS icon/preview; optional
                                   under-tile filename caption. recompute() branches on imageLayout
                                   (fixed ratio → uniform aspect array)
    ImageLayoutSheet.swift         grid-button modal setting AppState.imageLayout — a grid of the
                                   12 ImageLayout tiles over a "Common Sizes" reference. LayoutTile
                                   takes the active MoodPalette so the modal flips with the mood
    SheetCloseButton.swift         shared circular hover-✕ for modal sheets (Esc via cancelAction)
    SelectionMenu.swift            SelectionActionsMenu — Add to Collection / New Collection from
                                   Selection / Add Tag / Share / Move to Folder over the effective
                                   selection. File-only actions consume a folder-filtered fileURLs
                                   subset and hide when empty
    OutsideClickDeselect.swift     0×0 NSView + window monitor clearing selection on any click
                                   outside the grid's scroll view
    PageScrollCatcher.swift        first-responder NSView owning the grid's keyboard: plain arrows MOVE
                                   the highlight (GridKeyboardNav) + auto-scroll (GridScrollReveal),
                                   plain Space OPENS (double-click path), Fn+arrow / Page Up/Down page
                                   via PageScroll math; everything else forwards down the chain
    ShareCollectionButton.swift    in-collection header menu — Save to… / Share / Share Drive Link;
                                   builds an 11×14 paginated PDF. exportURLs = visibleFiles minus folders
                                   (the on-screen filtered grid). Passes imageLayout.aspect +
                                   effectiveTileBackground + activeTagLabels so the PDF mirrors the grid.
                                   Drive → DriveShareSheet. (iCloud "Share Link" backend removed 2026-06-25
                                   — NSSharingServicePicker can't mint an iCloud Copy Link for app-container
                                   files; see CLAUDE.md. Drive is the only link path.)
    DriveShareForm.swift           DriveShareSheet: publish form (page title/label/name/expiry, remembered)
                                   → progress (DriveShareService.phase) → finished link (Copy / Share)
    ManageDriveSharesView.swift    View-menu "Manage Drive Shares…" sheet (InfoSheet-styled): open link /
                                   unpublish (delete the Drive folder now)
    AspectRatioCache.swift         per-file aspect (h÷w) for layout: bulk DB width/height + ImageIO
                                   header fallback, off-main
    CollectionsPage.swift          dedicated Collections page (toolbar square.stack.3d.up):
                                   "Collections" header (back + "+" New Collection) over a 4-up card
                                   grid; ordered by the toolbar sort via CollectionSort. "+" opens
                                   the shared "Name Collection" modal
    CollectionsRow.swift           in-collection header (back/rename/count) + CollectionCard
                                   (right-click → Delete, DURABLE via setHidden)
    TagChipsRow.swift              tag chips; filter + management. A pure RENDERER of
                                   AppState.tagChipRows; hover-count layout (ChipFlow) +
                                   rename/delete dialogs. Scope decided by AppState.tagSourceFiles
    MoodPickerView.swift           background popover (Light/Dark/Auto/Custom) + a "Tile Background"
                                   section (→ AppState.tileBackground; disabled→Auto in masonry)
    GridFilterPopover.swift        the funnel-button popover (mood-picker chrome, fixed 180 wide):
                                   one KIND section — an "Images" tri-state checkbox (native NSButton
                                   allowsMixedState, driven from imageParentState) over the always-
                                   visible image-FORMAT checkboxes + the top-level kind checkboxes +
                                   Clear All. NO expand/collapse dropdown (broke resize — see gotcha),
                                   NO date/size. Funnel lives in the sort cluster; engaged-blue when active
    InfoSheet.swift                ⓘ About-Muse modal (behavior + privacy); SheetCloseButton; has a
                                   "Back Up & Restore" section
    Backup/
      ReconnectWizard.swift        the locked Restore sheet (InfoSheet chrome 600×720, Done only).
                                   Folder rows with per-row Locate… + ✓/flagged/failed status; renders
                                   ReconnectModel (matching/applying live in the pure Backup/ cores)
    KeyCaptureView.swift           NSView arrow/return capture (hero flips)
    BreadcrumbView.swift           path breadcrumb (kept; not in toolbar)
    OpenWithMenu.swift             NSWorkspace registered apps via LaunchServices
    ImageDetailPanel.swift         fit/100% preview overlay
    QuickLookFallback.swift        QLPreviewView wrapper
    ViewerRouter.swift             AssetKind → viewer dispatch (image/raw/psd → HeroImageViewer;
                                   .video → HeroVideoViewer; rest → ViewerChrome-wrapped)
    DuplicatesView.swift           review pane with delete-to-Trash. Each duplicate is a grid-style
                                   tile (DuplicateImageTile); non-keepers pre-marked; KEEP badge tracks
                                   survivors. All rules + the "never fully delete a group" guarantee
                                   live in the pure DuplicateDeleteRules; this view is a thin renderer
    Viewer/                        hero image viewer (HeroImageViewer, HeroStage, ViewerInfoColumn,
                                   backdrop, geometry, toast, PillFlow/PillRowModel). ViewerInfoColumn
                                   renders an INFO card (below COLORS) from FileMetadata — labeled rows,
                                   collapsible +/× header, text-only "Open in Maps" link (no inline map).
                                   Subtitle line is size · dimensions only
      HeroVideoViewer.swift        the hero viewer for VIDEOS: reuses ViewerBackdrop (wash from
                                   HeroPalette.videoPalette) + ViewerInfoColumn + ViewerToast, centering
                                   an aspect-fit VideoPlayerView. Simpler than HeroImageViewer — NO zoom/
                                   pan/flight/arrow-flip; Share + ✕ only. Backdrop leads, video stage
                                   fades in ~0.22s later. delete's completeDelete nav writes guarded to
                                   the on-screen file
      ShareButton.swift            macOS share sheet (NSSharingServicePicker) for the hero image
    Spatial/
      SeededRandom.swift           SplitMix64 + FNV-1a (kept: grid seed + hero). Cloud/Galaxy views removed
  Components/
    (search field: now native SwiftUI `.searchable` in ContentView — All/This Folder
     via `.searchScopes`, 250ms debounce; the old NativeSearchField was removed 2026-07-02)
    GridSelection.swift            pure selection math (single / Cmd-toggle / Shift-range → set +
                                   anchor), unit-tested
    PageScroll.swift               pure Page Up/Down math (newOriginY: overlap + clamp), unit-tested
    ReorderMath.swift              pure sidebar live-drag reorder arithmetic shared by the folder AND
                                   collection reorders. SidebarView keeps the @State + gestures + the
                                   SYNCHRONOUS commit; delegates the math here. Unit-tested
    EscapeAction.swift             pure Escape priority resolver: peel one focused layer per press —
                                   viewer → search → tags → collection → Collections page → grid.
                                   ContentView's hidden Escape button maps the result onto AppState calls;
                                   viewer always wins. Unit-tested
    MasonryGeometry.swift          pure masonry packing (frames + height) from aspect ratios — feeds
                                   GridView's virtualization. captionHeight param reserves a per-tile
                                   caption strip
    GridKeyboardNav.swift          pure arrow-move index math over the masonry frames: ←/→ = ±1 in
                                   reading order (wrap+clamp), ↑/↓ = nearest row-band then closest
                                   horizontal centre. Feeds PageScrollCatcher's onArrow. Unit-tested
    GridScrollReveal.swift         pure clip-view "scroll the highlighted tile into view" math
                                   (flipped coords, margin, top/bottom clamp). Unit-tested
    ICloudSidebarVisibility.swift  pure decider for whether the app-managed iCloud "Muse" root shows in
                                   the sidebar (presence from live recursive file count → rowVisible /
                                   toggleDisabled). One source of truth shared by SidebarView's render
                                   gate + SettingsView's "Show iCloud Folder in the Sidebar" toggle.
                                   Unit-tested
  Backup/                          Library Backup & Restore. Export one self-contained `.muselibrary`
                                   file + reconnect it on another Mac by content hash
    BackupArchive.swift            pure Codable model; reuses Sidecar for per-file metadata.
                                   Membership/cover re-keyed to content_hash (FileRow.id UUID isn't
                                   portable). Unit-tested
    BackupDocument.swift           encode/decode the archive ↔ Data (JSON); `.muselibrary`; rejects
                                   schema mismatch
    BackupBuilder.swift            DB → BackupArchive (off-main read). Only alive-path files exported;
                                   membership/cover/exclusions re-keyed to content_hash. Unit-tested
    ReconnectMatcher.swift         pure: classify archive occurrences vs the disk files the indexer
                                   hashed — exact (hash) first, then filename fallback, else unmatched;
                                   no disk file used twice. Unit-tested
    CollectionMaterializer.swift   pure: archive collections → rows, re-keying hash→file_id. Drops empty
                                   AUTO+visible; KEEPS empty manual OR hidden (tombstone). Unit-tested
    ReconnectApplier.swift         DB writer: applyMeta / applyCollections (ON CONFLICT preserves
                                   is_hidden) / applyStars / currentFileIDForHash. Unit-tested
    ReconnectModel.swift           @MainActor wizard model. Per folder (located one at a time): add as
                                   root, index, read disk files back, match, applyMeta/Collections/Stars,
                                   CollectionsEngine.reload(), then analyzePending reconciles new files
  Export/
    CollectionPDFLayout.swift      pure paginated masonry pack for the collection PDF (no image split
                                   across pages); each tile reserves a captionHeight strip. Unit-tested
    CollectionPDFExporter.swift    ImageIO downsample (off-main) → CGPDFContext; CoreText 11×14 header +
                                   ellipsis-truncated filename caption per image. makePDF mirrors the grid
                                   (fixed ratio → uniform aspect array; per-image backdrop; non-image →
                                   QuickLook; decode 8-wide, order preserved) and draws active tagLabels as
                                   header pills on page 1 (width-clamped + truncated)
  Sharing/                         (iCloud backend #1 REMOVED 2026-06-25 — NSSharingServicePicker can't
                                   mint an iCloud Copy Link for app-container files; Drive is the only
                                   link path. See CLAUDE.md. ICloudZone.swift stays under Filesystem/ for
                                   iCloud *sync*.)
  Sharing/Drive/                   collection share: Google Drive (the only sanctioned network feature)
    PKCE.swift                       RFC 7636 S256 verifier/challenge/state. Pure. Unit-tested
    TokenStore.swift                 DriveTokens + TokenStoring; Keychain (device-only) + in-memory double
    DriveConfig.swift                owner placeholders: clientID, reverse-client-id scheme, shareBaseURL
    GoogleOAuth.swift                Auth-Code+PKCE via ASWebAuthenticationSession; exchange/refresh/revoke
    DriveClient.swift                Drive v3 REST (ensureMuseRoot/createFolder/uploadFile multipart/
                                     setAnyoneReader/deleteFolder); uploadFile strips metadata first;
                                     pure multipartBody is unit-tested
    ImageMetadataStripper.swift      strips GPS/EXIF/camera/IPTC/XMP/maker-notes/thumbnail before upload
                                     (single-frame re-encodes from pixels = clean by construction;
                                     multi-frame stays lossless; every output re-verified via isClean;
                                     fail-closed). Adversarial-tested per format (HEIC/PNG/TIFF/GIF/…)
    DriveShareManifest.swift         base64url URL-FRAGMENT payload (mirrors share.js keys). Unit-tested
    DriveShareRecord.swift           DriveShareRecord + DriveShareStore (JSON, App Support) + DriveExpiry
    DriveShareService.swift          @MainActor publish orchestrator (Phase signingIn/uploading/…/done)
    DriveExpirySweeper.swift         launch sweep: delete folders past expiry (only if signed-in + due)
  web/share/                       static Cloudflare page (NOT in the app target)
    index.html · share.css           shell + styles matching the mockups
    share.js                         decode/validate/expiry/render (textContent only); + share.test.mjs
    _headers · README.md             strict CSP/hardening; deploy + OAuth-setup docs
  Effects/                         (was Fluid/; water + burn shaders removed — NO Metal shaders remain)
    FadeOutModifier.swift          animatable staggered opacity fade for the delete sequence
  Settings/
    AppSettings.swift              UserDefaults accessors: auto-organization opt-outs (autoTag/
                                   autoCollections, default ON), showFileNames, folderSortMode,
                                   collectionSortMode/Reversed, imageLayout, tileBackground, gridFilter
                                   (JSON). Read by AnalyzePipeline/CollectionsEngine/GridView; mirrored on AppState
    SettingsView.swift             Settings as an IN-APP MODAL SHEET (not the native Preferences window)
                                   — opened by AppState.settingsShown from CommandGroup(replacing:
                                   .appSettings) (⌘,). Sections: auto-organization toggles, Grid (Show
                                   file names), Sidebar (Show Collections in the Sidebar)
  Muse.entitlements                app-sandbox + user-selected.read-write + bookmarks.app-scope + iCloud
                                   Documents + network.client (Sparkle update fetch ONLY) + mach-lookup
                                   temporary-exception for Sparkle's installer XPC. DEBUG builds sign with
                                   Muse-Debug.entitlements (same keys MINUS iCloud) to protect the production
                                   iCloud container
  Muse-Debug.entitlements          Debug-only: Muse.entitlements without the three iCloud keys
                                   (Release/App Store keep iCloud)
MuseShareExtension/                (separate app-extension target) "Send to Muse" — Finder Share-menu
                                   extension; copies dropped files into the single iCloud folder, picked
                                   up by the existing FolderWatcher
```
