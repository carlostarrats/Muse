//
//  GridView.swift
//  Muse
//
//  Virtualized masonry grid. The jigsaw packing is precomputed in plain
//  Swift (MasonryGeometry) from stored aspect ratios (AspectRatioCache), so
//  only the tiles inside the viewport (+ overscan) are ever materialized.
//  This is what keeps a 1700+ image folder smooth: a handful of live tiles
//  instead of the whole library, and no per-frame O(n) relayout.
//

import SwiftUI
import AppKit

struct GridView: View {
    @EnvironmentObject var appState: AppState
    // Observed so the first-run empty state reacts to reachable-content changes
    // (e.g. the last images going away leaves an empty library that needs the
    // "add a folder" guidance, even while the always-present iCloud root remains).
    @ObservedObject private var collectionsEngine = CollectionsEngine.shared

    private let spacing: CGFloat = 14
    private let contentInset: CGFloat = 20
    @State private var addTagFile: FileNode? = nil
    @State private var newTagText = ""
    /// User-set images-per-row, persisted; the bottom-right slider drives it.
    @AppStorage("gridColumnCount") private var gridColumns = 4
    /// Off-by-default: show each file's name under its tile.
    @AppStorage(AppSettings.showFileNamesKey) private var showFileNames = false
    /// On-by-default: show the star-rating badge on tiles. Off hides it in the
    /// MAIN (folder) grid only — badges still show inside a collection (and in
    /// the hero viewer, which is a separate control).
    @AppStorage(AppSettings.showStarsOnGridKey) private var showStarsOnGrid = true
    /// Fixed under-tile caption strip height (one line of `.caption`), constant
    /// across column counts — matches the collection-PDF export's fixed caption.
    private let captionStripHeight: CGFloat = 18

    /// The caption height actually reserved this render (0 when names are off).
    private var effectiveCaptionHeight: CGFloat {
        showFileNames ? captionStripHeight : 0
    }

    /// Whether rating badges show on the current grid: always when viewing a
    /// collection; on the main folder grid only when the setting is on.
    private var showsRatingBadges: Bool {
        showStarsOnGrid || appState.activeCollectionID != nil
    }

    /// Manual double-click detection so single-click selection is INSTANT —
    /// a lone `onTapGesture` fires immediately, with no SwiftUI count:1-vs-2
    /// disambiguation delay. A second quick tap on the same tile opens it.
    @State private var lastTapPath: String?
    /// Hardware timestamp (seconds since boot) of the last tap's originating
    /// event — NOT a wall-clock `Date`. See `handleTileTap`.
    @State private var lastTapAt: TimeInterval = 0

    private func handleTileTap(_ file: FileNode) {
        let p = file.url.standardizedFileURL.path
        // Measure the gap from the originating EVENT's hardware timestamp
        // (seconds since boot), not from `Date()` sampled when this handler
        // runs. On a slow machine the first click's selection can stall the
        // main thread long enough that the second click's handler is delivered
        // late — `Date()` would then time the handler latency, not the user's
        // actual click cadence, and miss the double-click (the "double-click
        // does nothing" bug older Intel Macs hit in a filtered tag/collection
        // view). The event timestamp reflects when the click physically
        // happened, so it's immune to that stall. The window also honors the
        // user's System Settings double-click speed, floored at the old 0.35s
        // so it's never stricter than before.
        let now = NSApp.currentEvent?.timestamp ?? ProcessInfo.processInfo.systemUptime
        let window = max(NSEvent.doubleClickInterval, 0.35)
        if lastTapPath == p, now - lastTapAt < window {
            lastTapPath = nil
            if file.kind == .folder {
                appState.openSubfolder(file.url)  // double-click → navigate in
            } else {
                appState.selectedFile = file      // double-click → open viewer
            }
            return
        }
        lastTapPath = p
        lastTapAt = now
        let m = NSEvent.modifierFlags
        if m.contains(.shift) { appState.applyClick(.range(p)) }
        else if m.contains(.command) { appState.applyClick(.toggle(p)) }
        else { appState.applyClick(.single(p)) }
    }

    @StateObject private var aspects = AspectRatioCache()

    // Precomputed layout (recomputed only when the file set, column count,
    // width, or resolved aspect ratios change — never on scroll).
    @State private var frames: [CGRect] = []
    @State private var totalHeight: CGFloat = 0
    @State private var layoutWidth: CGFloat = 0

    /// The masonry canvas's top, in the scroll viewport's coordinate space.
    /// 0 at the top; goes negative as the user scrolls down.
    @State private var canvasMinY: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let contentWidth = max(0, geo.size.width - contentInset * 2)

            ScrollView {
                ZStack(alignment: .topLeading) {
                // Reliable deselect surface spanning the full scroll content,
                // the top inset included. Sits BEHIND the tiles — they keep
                // their own select taps; a tap on empty space here clears the
                // selection. Without it the grid's top inset doesn't deselect
                // on the no-tags layout, where that strip sits right under the
                // toolbar instead of behind the tag chips (which deselect via
                // OutsideClickDeselect). Keeps deselect identical with or
                // without tags. The ScrollView `.background` tap below is
                // viewport-pinned and unreliable for in-content clicks — this
                // is the content-level equivalent that actually fires.
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture { appState.clearSelection() }
                VStack(alignment: .leading, spacing: 0) {
                    // Keyboard navigation for the grid:
                    // • plain arrows MOVE the highlighted tile (+ auto-scroll),
                    // • plain Space OPENS it (hero viewer / navigate-in), same as
                    //   double-click,
                    // • Fn+arrow / Page keys page-scroll (unchanged).
                    // Inactive while a hero viewer covers the grid. The frames
                    // array is the FULL precomputed masonry (index-aligned with
                    // visibleFiles), so navigating to an off-screen tile has a
                    // valid frame with no full-set materialization — virtualization
                    // is untouched.
                    PageScrollCatcher(
                        isActive: { appState.selectedFile == nil },
                        onArrow: { direction in
                            let files = appState.visibleFiles
                            guard !files.isEmpty, !frames.isEmpty else { return nil }
                            let current = appState.currentKeyboardIndex(order: files)
                            // Band tolerance = the column width (uniform across the
                            // masonry) so a tile within one column-width of the
                            // nearest row-band top counts as that row.
                            let band = frames.first?.width ?? 1
                            guard let newIndex = GridKeyboardNav.next(
                                    currentIndex: current, direction: direction,
                                    frames: frames, bandTolerance: band),
                                  newIndex < files.count else { return nil }
                            appState.keyboardSelect(
                                path: files[newIndex].url.standardizedFileURL.path)
                            let f = frames[newIndex]
                            return KeyboardScrollTarget(
                                tileTopInViewport: canvasMinY + f.minY,
                                tileHeight: f.height)
                        },
                        onSpace: {
                            let files = appState.visibleFiles
                            guard let idx = appState.currentKeyboardIndex(order: files),
                                  idx < files.count else { return }
                            let file = files[idx]
                            // Exact double-click path: a folder navigates in, a
                            // file opens the hero viewer. NO Quick Look.
                            if file.kind == .folder {
                                appState.openSubfolder(file.url)
                            } else {
                                appState.selectedFile = file
                            }
                        })
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                    // Clicking anywhere outside the grid (sidebar, search,
                    // toolbar) deselects. Lives inside the grid scroll view so
                    // it can measure the grid's bounds.
                    OutsideClickDeselect(onOutsideClick: { appState.clearSelection() })
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                    // The in-collection header scrolls away with the page —
                    // only the tag chips above stay pinned. Shows whenever a
                    // collection is active, even with a tag filter on (so you
                    // can use tags within a collection). Returns nothing when
                    // no collection is active.
                    if !appState.isSearchActive {
                        CollectionsRow()
                    }
                    if appState.visibleFiles.isEmpty {
                        if appState.isLoadingFolder {
                            // Calm background while the folder enumerates — no fake
                            // skeleton tiles, which would sit at a top position the
                            // tag row later shifts. Content appears already in place.
                            Color.clear
                        } else {
                            emptyState(viewportHeight: geo.size.height)
                        }
                    } else if !(appState.isSearchActive || appState.tagRowReady) {
                        // Files are ready but the tag row hasn't sized yet — hold on
                        // the background so the images don't render at the top and
                        // then get shoved down when the chips appear. The row loads
                        // first; the images reveal already in place below it.
                        Color.clear
                    } else {
                        masonryCanvas(viewportHeight: geo.size.height)
                            .frame(width: contentWidth, height: totalHeight,
                                   alignment: .topLeading)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear
                                        .onAppear {
                                            canvasMinY = proxy.frame(in: .named("gridScroll")).minY
                                        }
                                        .onChange(of: proxy.frame(in: .named("gridScroll")).minY) { _, y in
                                            canvasMinY = y
                                        }
                                }
                            )
                            .padding(contentInset)
                            // Collection/tag switches replace the grid wholesale —
                            // one instant swap, not a per-tile reflow. Keyed on
                            // `tagFilterGeneration` (bumps with the RESOLVED
                            // `activeTagPaths`), not `activeTagLabels`. With the
                            // synchronous `setActiveTags` both land in one frame;
                            // keying on the generation stays the gap-proof rule.
                            .id("\(appState.activeCollectionID ?? "")|\(appState.tagFilterGeneration)")
                            // Instant swap, NOT `.opacity`. Both the outgoing and
                            // incoming canvas read the same global `visibleFiles`,
                            // so a symmetric opacity transition fades two identical
                            // layers in/out at once — the composite dips to ~75%
                            // and recovers (a visible dim of the NEW content, not a
                            // real A→B cross-fade, which shared state can't give us
                            // without snapshotting). `.identity` keeps the `.id`'s
                            // job — wholesale replace, no per-tile reflow — without
                            // the dim blip.
                            .transition(.identity)
                    }
                }
                }
            }
            .coordinateSpace(name: "gridScroll")
            // The empty state's `minHeight: viewportHeight` should make its
            // content exactly fill the viewport with nothing left to scroll —
            // but a ScrollView still permits its normal rubber-band drag/
            // bounce regardless of whether content actually overflows, which
            // reads as "not really centered" the moment you touch it. There's
            // nothing to scroll TO in the empty state, so disable it outright.
            .scrollDisabled(appState.visibleFiles.isEmpty)
            .background {
                // Tapping anywhere in the empty grid background (margins, gaps,
                // below the tiles) deselects. Tiles consume their own taps.
                appState.moodPalette.background
                    .contentShape(Rectangle())
                    .onTapGesture { appState.clearSelection() }
            }
            .animation(.easeInOut(duration: 0.35), value: appState.moodPalette)
            .overlay(alignment: .bottomTrailing) {
                if !appState.visibleFiles.isEmpty {
                    columnSlider
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                }
            }
            .alert("Add Tag", isPresented: Binding(
                get: { addTagFile != nil },
                set: { if !$0 { addTagFile = nil } }
            )) {
                TextField("Tag name", text: $newTagText)
                Button("Add") { commitAddTag() }
                Button("Cancel", role: .cancel) { addTagFile = nil }
            } message: {
                Text("Tags “\(addTagFile?.basename ?? "")”.")
            }
            .onAppear {
                aspects.load(appState.visibleFiles)
                recompute(width: contentWidth)
            }
            .onChange(of: geo.size) { _, newSize in
                recompute(width: max(0, newSize.width - contentInset * 2))
            }
            .onChange(of: gridSignature) { _, _ in
                // Drop the previous set's cached ratios before loading the new one,
                // so the cache stays bounded to roughly the on-screen folder.
                aspects.prune(toVisible: appState.visibleFiles)
                aspects.load(appState.visibleFiles)
                recompute(width: contentWidth)
            }
            .onChange(of: gridColumns) { _, _ in
                withAnimation(.easeInOut(duration: 0.25)) {
                    recompute(width: contentWidth)
                }
            }
            .onChange(of: showFileNames) { _, _ in
                withAnimation(.easeInOut(duration: 0.25)) {
                    recompute(width: contentWidth)
                }
            }
            .onChange(of: aspects.version) { _, _ in
                // Fixed-ratio layouts ignore per-image aspects, so a decoded
                // thumbnail reporting its real ratio must NOT trigger a relayout
                // (it would churn the whole grid for no visual change).
                guard appState.imageLayout.aspect == nil else { return }
                recompute(width: contentWidth)
            }
            .onChange(of: appState.imageLayout) { _, _ in
                withAnimation(.easeInOut(duration: 0.25)) {
                    recompute(width: contentWidth)
                }
            }
        }
    }

    // MARK: - Virtualized canvas

    /// Renders only the tiles whose precomputed frame intersects the viewport
    /// (plus a one-screen overscan above and below for smooth scrolling).
    @ViewBuilder
    private func masonryCanvas(viewportHeight: CGFloat) -> some View {
        let visibleTop = -canvasMinY
        let overscan = max(300, viewportHeight)
        let lo = visibleTop - overscan
        let hi = visibleTop + viewportHeight + overscan
        let files = appState.visibleFiles
        // Hero parting: while a clicked tile's image is flying up to the hero
        // viewer, every OTHER tile slides radially away from the clicked spot
        // (and converges back when the return flight starts — viewerDismissing
        // flips at that moment). Keyed off selectedFile, matching the tile
        // image's handoff opacity gate. Pure per-mounted-tile offsets on top
        // of the static masonry frames: no relayout, virtualization untouched.
        // Gated to the hero-image kinds (image/raw/psd) that actually FLY from
        // the tile — every other kind opens via ViewerChrome (a centered
        // fade-in, nothing growing out of the tile), so parting there would
        // imply a flight that isn't happening.
        let partingClicked: CGRect? = {
            guard let hero = appState.selectedFile,
                  hero.kind == .image || hero.kind == .raw || hero.kind == .psd,
                  !appState.viewerDismissing,
                  let i = files.firstIndex(where: { $0.url == hero.url }),
                  i < frames.count else { return nil }
            return frames[i]
        }()

        ZStack(alignment: .topLeading) {
            // Click empty space to deselect. Sits behind the tiles, so a tap on
            // a tile is handled by the tile, not this.
            Color.clear
                .frame(width: layoutWidth, height: totalHeight)
                .contentShape(Rectangle())
                .onTapGesture { appState.clearSelection() }
            ForEach(visibleIndices(lo: lo, hi: hi, count: files.count), id: \.self) { i in
                let rect = frames[i]
                let file = files[i]
                let parting = partingClicked.map {
                    PartingField.displacement(
                        for: rect, clicked: $0,
                        // The same amplitude that reads organic in masonry's
                        // jigsaw reads exaggerated across a uniform lattice —
                        // fixed-aspect layouts run the motion damped.
                        strength: appState.imageLayout.aspect == nil
                            ? 1 : PartingField.gridModeStrength)
                } ?? .identity
                TileView(file: file, order: i, deletion: appState.deletion,
                         showFileNames: showFileNames,
                         captionHeight: effectiveCaptionHeight,
                         rating: showsRatingBadges
                             ? appState.starRatings[file.url.standardizedFileURL.path] : nil,
                         reportAspect: { [weak aspects] ratio in
                             aspects?.report(aspect: ratio,
                                              forStandardizedPath: file.url.standardizedFileURL.path)
                         })
                    .frame(width: rect.width, height: rect.height)
                    // Instant single-click select (Cmd toggles, Shift ranges);
                    // a second quick tap opens. Selection border lives inside
                    // TileView so it scales with the hover zoom.
                    .onTapGesture { handleTileTap(file) }
                    // Drag onto a sidebar folder to move. Dragging an unselected
                    // tile first selects just it, so the drop moves the right set.
                    .onDrag {
                        guard file.kind != .folder else { return NSItemProvider() }
                        let p = file.url.standardizedFileURL.path
                        if !appState.selectedFiles.contains(p) {
                            appState.applyClick(.single(p))
                        }
                        return NSItemProvider(object: file.url as NSURL)
                    }
                    // Shrink about the tile's own center, ease outward, and
                    // fade — the fade carries the effect (the reference's
                    // neighbors are mostly gone by 0.15s; the motion is felt,
                    // not watched). The source tile keeps identity + full
                    // opacity: its image handoff has its own gate above.
                    .scaleEffect(parting.scale)
                    .opacity(parting == .identity ? 1 : PartingField.partedOpacity)
                    .offset(x: rect.minX + parting.offset.width,
                            y: rect.minY + parting.offset.height)
                    // Value-scoped so ONLY hero open/close animates the
                    // scale/offset/fade — the placement component must stay
                    // instant on scroll and relayout. Open: ~0.25s with a
                    // per-tile distance delay so the shrink ripples outward
                    // from the click. Close: one un-staggered easeOut
                    // converge — NOT easeInOut: its dead-slow start under the
                    // simultaneous opacity fade-in read as stop-start jitter
                    // (motion happening while barely visible, popping into
                    // view mid-move). easeOut moves immediately and settles
                    // before the 0.34s landing.
                    .animation(partingClicked == nil
                                   ? .easeOut(duration: 0.3)
                                   : .easeOut(duration: 0.25)
                                       .delay(PartingField.openDelay(
                                           distance: parting.distance)),
                               value: partingClicked)
                    .accessibilityElement(children: .ignore)
                    // Folder cards have only an icon on screen — name the kind so
                    // VoiceOver disambiguates a folder from a file.
                    .accessibilityLabel(file.kind == .folder
                                        ? String(localized: "\(file.basename), folder") : file.basename)
                    // Expose selection to VoiceOver, not just via the color/border.
                    .accessibilityAddTraits(
                        appState.selectedFiles.contains(file.url.standardizedFileURL.path)
                            ? [.isButton, .isSelected] : .isButton)
                    // The rating badge is a11y-hidden (display-only overlay), so
                    // announce the rating here as the tile's value.
                    .accessibilityValue(
                        (showsRatingBadges
                            ? appState.starRatings[file.url.standardizedFileURL.path] : nil).map {
                            Text(String(format: NSLocalizedString(
                                "%lld-star rating",
                                comment: "VoiceOver: star rating of a photo"), $0))
                        } ?? Text(""))
                    // Primary VoiceOver action = OPEN. The mouse opens via the
                    // double-click timing window, which VoiceOver can't reproduce,
                    // so activating a tile only SELECTED it before — there was no
                    // keyboard/VoiceOver path to open. A file opens the viewer
                    // (`selectedFile`, the exact trigger double-click uses); a
                    // folder navigates IN (`openSubfolder`, what its double-click
                    // does) — applying the file path to a folder would wrongly
                    // route it to a viewer.
                    .accessibilityAction {
                        if file.kind == .folder {
                            appState.openSubfolder(file.url)
                        } else {
                            appState.selectedFile = file
                        }
                    }
                    .accessibilityHint(file.kind == .folder
                                       ? String(localized: "Opens the folder.") : String(localized: "Opens in the viewer."))
                    .contextMenu {
                        if file.kind == .folder {
                            // A folder card behaves like a sidebar subfolder:
                            // New Subfolder / Rename / Reveal — nothing else.
                            Button("New Subfolder…") {
                                if let n = appState.resolveFolderNode(file.url) {
                                    appState.requestNewSubfolder(n)
                                }
                            }
                            if file.url.standardizedFileURL
                                != appState.iCloudFolderURL?.standardizedFileURL {
                                Button("Rename Folder…") {
                                    if let n = appState.resolveFolderNode(file.url) {
                                        appState.requestRenameFolder(n)
                                    }
                                }
                            }
                            Divider()
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            }
                        } else {
                            let p = file.url.standardizedFileURL.path
                            // Single-image items show only when the effective
                            // selection is one image (this tile, or a 1-item set).
                            let single = !appState.selectedFiles.contains(p)
                                || appState.selectedFiles.count <= 1
                            SelectionActionsMenu(path: p)
                            Divider()
                            if single {
                                OpenWithMenu(url: file.url)
                                Button("Rename…") { appState.requestRenameFile(file) }
                                if appState.activeCollectionID != nil {
                                    Button("Set as Collection Cover") {
                                        appState.setCollectionCover(file)
                                    }
                                }
                                Divider()
                            }
                            Button("Move to Trash", role: .destructive) {
                                let targets = appState.effectiveSelectionURLs(fallback: p)
                                let byPath = Dictionary(
                                    appState.visibleFiles.map { ($0.url.standardizedFileURL.path, $0) },
                                    uniquingKeysWith: { a, _ in a })
                                Task { @MainActor in
                                    for url in targets {
                                        // Never trash a selected folder card — folders
                                        // stay out of file-only destructive flows (a
                                        // folder is selectable like a file, so a mixed
                                        // selection could otherwise recycle a whole
                                        // subfolder tree). Folder ops live on the
                                        // folder-card menu (New Subfolder/Rename/Reveal).
                                        if let node = byPath[url.standardizedFileURL.path],
                                           node.kind != .folder {
                                            await appState.deletion.deleteWithBurn(node)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Folder cards expose their right-click items (New Subfolder /
                    // Rename / Reveal) as named VoiceOver actions too, so folders
                    // stay manageable without a mouse now that the hint no longer
                    // mentions "right-click". No-op for file tiles. Rename is
                    // omitted for the iCloud folder, matching its context menu.
                    .folderCardActions(
                        file.kind == .folder,
                        newSubfolder: {
                            if let n = appState.resolveFolderNode(file.url) {
                                appState.requestNewSubfolder(n)
                            }
                        },
                        rename: file.url.standardizedFileURL
                            == appState.iCloudFolderURL?.standardizedFileURL
                            ? nil
                            : {
                                if let n = appState.resolveFolderNode(file.url) {
                                    appState.requestRenameFolder(n)
                                }
                            },
                        reveal: {
                            NSWorkspace.shared.activateFileViewerSelecting([file.url])
                        })
                    .fileTileActions(file.kind != .folder) {
                        appState.requestRenameFile(file)
                    }
                    // Tie tile identity to the FILE, not the positional index the
                    // ForEach iterates. The virtualized ForEach is keyed by slot
                    // index (`id: \.self`), so when the grid reorders (e.g. an
                    // in-place edit bumps modified_at and a date sort floats the
                    // file to the top) a slot rebinds to a different file while
                    // SwiftUI reuses the cell — and the cell's decoded @State
                    // bitmap outlives the rebind, briefly showing one file's image
                    // on another file's tile until a full remount. A file-stable
                    // .id forces a clean remount on rebind (fresh thumbnail state),
                    // so a tile can never display a different file's cached bitmap.
                    // Keyed on the path (stable across content edits), so an
                    // in-place edit of THIS file still refreshes smoothly via the
                    // task's content-version id rather than remounting.
                    .id(file.url.standardizedFileURL.path)
            }
        }
        .frame(width: layoutWidth, height: totalHeight, alignment: .topLeading)
    }

    /// Indices of tiles whose frame lies within [lo, hi] of content Y. A linear
    /// scan over the precomputed frames — cheap enough to run every scroll tick.
    private func visibleIndices(lo: CGFloat, hi: CGFloat, count: Int) -> [Int] {
        guard !frames.isEmpty else { return [] }
        let n = min(count, frames.count)
        var out: [Int] = []
        out.reserveCapacity(96)
        for i in 0..<n {
            let f = frames[i]
            if f.maxY >= lo && f.minY <= hi { out.append(i) }
        }
        return out
    }

    /// Recompute the full masonry packing. Called only on set/column/width/
    /// aspect changes — not on scroll.
    private func recompute(width: CGFloat) {
        let files = appState.visibleFiles
        guard width > 0, !files.isEmpty else {
            frames = []
            totalHeight = 0
            layoutWidth = width
            return
        }
        // Fixed-ratio layouts give every tile one aspect (uniform aspects make
        // MasonryGeometry pack a row-major grid); masonry uses each image's
        // natural ratio from the cache.
        let ratios: [CGFloat]
        if let fixed = appState.imageLayout.aspect {
            ratios = Array(repeating: fixed, count: files.count)
        } else {
            ratios = files.map { aspects.aspect(for: $0) }
        }
        let result = MasonryGeometry.compute(aspects: ratios,
                                             columns: gridColumns,
                                             width: width,
                                             spacing: spacing,
                                             captionHeight: effectiveCaptionHeight)
        frames = result.frames
        totalHeight = result.totalHeight
        layoutWidth = width
    }

    /// Cheap signature of everything that changes the *set* of files shown
    /// (folder, sort, collection/tag filters, search). Avoids mapping 1700
    /// ids on every render just to drive an onChange.
    private var gridSignature: String {
        let files = appState.visibleFiles
        return [
            String(files.count),
            appState.selectedFolder?.id.uuidString ?? "",
            appState.activeCollectionID ?? "",
            appState.activeTagLabels.joined(separator: "\u{1f}"),
            appState.isSearchActive ? "s" : "",
            appState.searchQuery,
            String(describing: appState.sortMode),
            files.first?.url.path ?? "",
            files.last?.url.path ?? ""
        ].joined(separator: "|")
    }

    private func commitAddTag() {
        guard let file = addTagFile else { return }
        let label = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        addTagFile = nil
        guard !label.isEmpty else { return }
        Task { @MainActor in
            _ = await TagStore.shared.addManualTag(label: label, for: file.url)
            appState.tagsVersion += 1
        }
    }

    /// Floating zoom control: fewer columns (bigger images) on the left,
    /// more (smaller) on the right.
    private var columnSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                // Decorative min/max hint — the slider itself carries the label.
                .accessibilityHidden(true)
            Slider(value: Binding(
                get: { Double(gridColumns) },
                set: { gridColumns = Int($0.rounded()) }
            ), in: 2...8, step: 1)
            .frame(width: 130)
            .controlSize(.small)
            .accessibilityLabel("Images per row")
            Image(systemName: "square.grid.4x3.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        // Match the status pills exactly: same 20pt content height + 9pt
        // vertical padding so every bottom capsule is the same height.
        .frame(height: 20)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .help("Images per row")
    }

    /// Takes the viewport height explicitly (mirrors `masonryCanvas(viewportHeight:)`
    /// above) — a ScrollView doesn't hand its content a bounded height, so
    /// `.frame(maxHeight: .infinity)` alone would just collapse to intrinsic
    /// size instead of actually filling the visible area, leaving this
    /// pinned near the top instead of centered.
    @ViewBuilder
    private func emptyState(viewportHeight: CGFloat) -> some View {
        // A plain empty folder shows nothing — just blank space. The one state
        // that needs guidance is an empty LIBRARY: NO folders at all (first run, or a
        // non-iCloud user who removed every folder — `rootNodes.isEmpty`), OR only the
        // always-present, empty iCloud "Muse" root left (`!hasReachableContent`). Both
        // must show the "add a folder" onboarding; folder-existence ALONE missed the
        // iCloud case, and content ALONE misses genuine zero-roots (the reachable-count
        // sentinel reads as "unknown → has content" when no roots are pushed). A
        // collection filter with no members, or one empty folder while others hold
        // images, both stay blank by design (the header already explains where you are).
        if appState.activeCollectionID == nil
            && (appState.rootNodes.isEmpty || !collectionsEngine.hasReachableContent) {
            VStack(spacing: 16) {
                Text("Get started by adding a folder")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                AddFolderPillButton { appState.pickAndAddRoot() }
                    .fixedSize()
            }
            // `.padding` must come BEFORE `.frame(minHeight:)`, not after —
            // padding applied after adds its own inset on TOP of the already-
            // viewport-tall frame (80pt total, 40 top + 40 bottom), so the
            // real content became taller than the visible viewport. With
            // scroll disabled the overflow just clips instead of scrolling
            // into view, and the centered text reads as sitting too low.
            // Padding first keeps the padded content small, so the frame's
            // minHeight is what actually determines the total size.
            .padding(40)
            .frame(maxWidth: .infinity, minHeight: viewportHeight)
        }
    }
}

/// Identity for a tile's thumbnail-load task: re-fetch when the file changes
/// path OR when its content version bumps (an in-place edit / iCloud sync).
private struct TileLoadID: Hashable {
    let url: URL
    let version: Int
}

private struct TileView: View {
    @EnvironmentObject var appState: AppState
    let file: FileNode
    /// Visual position in the grid — thumbnail loads are served in this
    /// order, so a cold folder fills top-to-bottom.
    var order: Int = 0
    @ObservedObject var deletion: DeleteCoordinator
    /// Whether to show a filename caption strip below the tile.
    var showFileNames: Bool = false
    /// Reserved caption strip height (0 when names are off).
    var captionHeight: CGFloat = 0
    /// Star rating (1...5) for this file, or nil when unrated. Drives the
    /// top-right badge. Passed from GridView so the tile re-renders when its
    /// rating changes without subscribing to the whole starRatings map.
    var rating: Int? = nil
    /// Reports the decoded thumbnail's exact aspect back to the layout so the
    /// tile frame matches the image (no grey letterbox).
    var reportAspect: (CGFloat) -> Void = { _ in }

    @State private var thumbnail: NSImage?
    @State private var hovering = false

    // MARK: - Selection / hover styling (dev-tunable; locked for production)
    /// Hover veil over an unselected tile (no size change).
    private static let hoverVeilOpacity = 0.2
    /// How far the image shrinks on each side when selected (reveals the gap).
    private static let selectionInset: CGFloat = 10
    /// How far the ring sits inside the tile's outer edge.
    private static let ringInset: CGFloat = 0
    /// Ring stroke thickness.
    private static let ringWidth: CGFloat = 2.5
    /// Ring corner radius. Set to 0 for a square ring.
    private static let ringCornerRadius: CGFloat = 8
    /// Tint laid over the selected (shrunken) image, in the ring's color.
    private static let selectionTintOpacity = 0.18

    /// True when this tile is multi-selected. (We deliberately do NOT treat the
    /// open file as selected: while a viewer is up its tile is hidden via the
    /// opacity gate below, so the `selectedFile` clause could only ever mark an
    /// invisible tile — and it made the close flight land the tile in its
    /// shrunk+ring selected state for a frame before `selectedFiles` cleared,
    /// reading as a stray hover/outline flash.)
    private var isSelected: Bool {
        appState.selectedFiles.contains(file.url.standardizedFileURL.path)
    }

    /// Whole-tile hero gate. Hidden while this tile's image is flying/open;
    /// comes back at close-flight start (viewerDismissing) in BOTH layouts,
    /// so the tile's card, star badge and caption are already in place when
    /// the image lands — anything appearing only at unmount read as
    /// drawn-after (owner bug reports, twice: first the grid-mode letterbox
    /// bars, then the masonry badge appearing late while grid's sat ready).
    /// The image itself stays gated separately for the instant landing
    /// handoff; masonry's early card reads as a placeholder plate the image
    /// lands onto, matching grid.
    private var heroHidden: Bool {
        appState.selectedFile?.url == file.url && !appState.viewerDismissing
    }

    /// Ring + tint color, decided once from the app background mood.
    private var ringColor: Color {
        switch SelectionStyle.accent(forBackground: appState.moodPalette.backgroundRGB) {
        case .systemBlue: return Color.accentColor
        case .black:      return Color.black
        case .white:      return Color.white
        }
    }

    private var isImageKind: Bool {
        file.kind == .image || file.kind == .raw || file.kind == .psd || file.kind == .svg
    }

    var body: some View {
        VStack(spacing: 0) {
            imageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showFileNames {
                Text(file.basename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: captionHeight)
                    .padding(.horizontal, 4)
                // (The whole tile is one a11y element via
                // .accessibilityElement(children: .ignore) in GridView's body,
                // so this caption is already excluded from VoiceOver.)
            }
        }
        .onHover { hovering = $0 }
        // Tracking areas ignore z-occlusion, so while the hero overlay is up
        // the invisible tile still collects hover state — and a stale
        // `hovering` would flash the dark veil the instant the tile reveals
        // on close (a hover flicker with the mouse nowhere near it, visually).
        // Reset on both edges of the hero session (hover accrues DURING it
        // too); a genuine hover re-arms on the next mouse move.
        .onChange(of: appState.selectedFile?.url == file.url) { _, _ in
            hovering = false
        }
        // Prototype's hidden-cell: the tile vanishes while its image is
        // flying/open so no ghost copy sits behind the hero stage (see
        // heroHidden for the grid-mode dismiss-start reveal).
        .opacity(heroHidden ? 0 : 1)
        // Hide is always instant. The grid-mode dismiss-start reveal eases
        // in under the returning flight; the unmount reveal stays instant
        // (viewerDismissing is already false in that frame) so the restore
        // lands in the same frame the hero unmounts.
        .animation(!heroHidden && appState.viewerDismissing
                       ? .easeIn(duration: 0.15) : nil,
                   value: heroHidden)
        // Delete = a quiet fade-out.
        .opacity(deletion.burningPaths.contains(file.url.path) ? 0 : 1)
        .animation(.easeOut(duration: 0.3),
                   value: deletion.burningPaths.contains(file.url.path))
        // Re-runs when the URL changes OR the file's content version bumps
        // (an in-place edit / iCloud sync).
        .task(id: TileLoadID(url: file.url, version: appState.contentToken(for: file))) {
            // 320 matches the hero viewer's first cache probe, so the open
            // flight starts from this exact bitmap with zero wait. Retry on nil
            // so a tile never stays grey: the QuickLook fallback (PDF, SVG,
            // fonts…) can transiently fail under load — a short backoff recovers
            // it instead of leaving a dead box.
            for attempt in 0..<4 {
                if let img = await ThumbnailCache.shared.thumbnail(
                    for: file.url,
                    size: CGSize(width: 320, height: 320),
                    order: order
                ) {
                    // Correct the tile's aspect from the real image BEFORE
                    // showing it, so the frame is already right when the image
                    // lands. Image kinds only: non-image cards keep their fixed
                    // labeled-card aspect (a QuickLook doc/icon thumbnail's
                    // proportions must not resize the card).
                    if isImageKind, img.size.width > 0 {
                        reportAspect(img.size.height / img.size.width)
                    }
                    thumbnail = img
                    return
                }
                if Task.isCancelled { return }
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(300_000_000) * UInt64(attempt + 1))
                }
            }
        }
    }

    /// The image area: the thumbnail/preview/card, clipped, with the selection
    /// overlay and the global-frame reporter for the hero open/close flight.
    /// The caption strip (if any) sits below this, OUTSIDE the selection border.
    private var imageContent: some View {
        ZStack {
            // When selected, the gap between the shrunken image and the ring
            // shows the app background (same color as the grid gutter), so the
            // image reads as lifted into the ring.
            if isSelected {
                Rectangle().fill(appState.moodPalette.background)
            }

            // The image. Square-cornered, natural aspect; shrinks inward when
            // selected to reveal the gap. The selection tint rides on top of it.
            tile
                .clipShape(Rectangle())
                .overlay {
                    if isSelected {
                        Rectangle().fill(ringColor.opacity(Self.selectionTintOpacity))
                    }
                }
                .padding(isSelected ? Self.selectionInset : 0)

            // Star-rating badge: top-right pill, BLACK glyphs on a near-white
            // (250,250,250) backing, no shadow. Placed BELOW the hover veil so it
            // darkens together with the tile on hover. Tracks the image: when
            // selected the image shrinks inward by selectionInset, so the badge
            // insets the same amount to stay pinned to the image's top-right
            // corner (not sticking out past the ring). Display-only (never
            // clickable — a tap would fight tile select/open); the rating is
            // announced via the tile's accessibilityValue in GridView.
            if let rating, let label = StarRating.label(for: rating) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule(style: .continuous)
                        .fill(Color(red: 250.0 / 255.0, green: 250.0 / 255.0, blue: 250.0 / 255.0)))
                    .padding(6)
                    .padding(isSelected ? Self.selectionInset : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topTrailing)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    // The tile's image reveals instantly on hero close (seamless
                    // handoff from the flying image — see the opacity gate below),
                    // but the badge has no hero counterpart, so it would snap in.
                    // Fade it in AT UNMOUNT (selectedFile clearing), NOT at the
                    // dismiss-start tile reveal: a badge over the image area gets
                    // covered by the landing flight in its final beat regardless
                    // (the flying image is in the overlay, above the grid), while
                    // one over letterbox bars would sit untouched — revealing at
                    // dismiss made the two read differently per layout/aspect
                    // (owner report). One uniform rule instead: every badge fades
                    // in right as the image lands. Other tiles never toggle this,
                    // so their badges stay constant.
                    .opacity(appState.selectedFile?.url == file.url ? 0 : 1)
                    .animation(.easeIn(duration: 0.16),
                               value: appState.selectedFile?.url == file.url)
            }

            // Hover veil — unselected tiles only; a calm dark wash, no resize.
            // Sits ABOVE the image AND the badge so both darken on hover.
            Rectangle()
                .fill(Color.black)
                .opacity((hovering && !isSelected) ? Self.hoverVeilOpacity : 0)
                .allowsHitTesting(false)

            // The padded ring, just inside the tile's outer edge.
            if isSelected {
                RoundedRectangle(cornerRadius: Self.ringCornerRadius, style: .continuous)
                    .strokeBorder(ringColor, lineWidth: Self.ringWidth)
                    .padding(Self.ringInset)
            }
        }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .background(
            GeometryReader { proxy in
                Color.clear
                    // Global tile frame feeds the hero open/close flight.
                    .onAppear {
                        appState.tileFrames[file.url.path] = proxy.frame(in: .global)
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, f in
                        // Neighbors are transform-warped while parting for a
                        // hero (and mid-converge on close): don't overwrite
                        // their rest frames with transient warped geometry —
                        // an arrow-flip close would fly to a warped rect, and
                        // the per-frame writes are churn. The SOURCE tile is
                        // never transformed and keeps reporting live, so the
                        // window-resize retarget stays exact.
                        guard appState.selectedFile == nil
                            || appState.selectedFile?.url == file.url else { return }
                        appState.tileFrames[file.url.path] = f
                    }
            }
        )
    }

    /// Images: natural aspect, fitted into the precomputed jigsaw frame.
    /// Other kinds: a grey card showing the native macOS icon / content preview.
    @ViewBuilder
    private var tile: some View {
        if isImageKind {
            // Placeholder stays put; the decoded image fades IN over it when it
            // lands, so a cold grid resolves as a soft fade.
            ZStack {
                Rectangle()
                    .fill(appState.tileFill)
                if thumbnail == nil {
                    let tuning = shimmerTuning(
                        isCustom: appState.mood == .custom,
                        isDark: appState.moodPalette.scheme == .dark)
                    ShimmerBand(peak: tuning.peak,
                                shoulder: tuning.shoulder,
                                blurRadius: 12)
                        .opacity(tuning.stackOpacity)
                }
                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .transition(.opacity)
                        // While this tile is the open hero, the IMAGE stays
                        // hidden even when the card is revealed for the grid
                        // close flight (heroHidden) — it must appear only in
                        // the unmount frame, as the seamless handoff from the
                        // flying image that lands exactly on its rect.
                        .opacity(appState.selectedFile?.url == file.url ? 0 : 1)
                        .animation(nil, value: appState.selectedFile?.url == file.url)
                }
            }
            .animation(.easeOut(duration: 0.28), value: thumbnail != nil)
        } else {
            // Non-image card: the QuickLook image is the real macOS TYPE ICON
            // (zip/dmg/folder) or a CONTENT preview (PDF/doc), centered and
            // scaled to fit. Falls back to an SF Symbol only while loading / if
            // QuickLook genuinely fails.
            ZStack {
                Rectangle()
                    .fill(appState.tileFill)
                if showFileNames {
                    // Name lives below the card (the body caption); show the
                    // icon/preview using the whole card.
                    cardIcon
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(12)
                } else {
                    // Name sits inside the card near the bottom; the centered
                    // icon/preview fills the area above it and never overlaps
                    // (they're stacked, not layered).
                    VStack(spacing: 6) {
                        cardIcon
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text(file.basename)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(cardNameColor)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(10)
                }
            }
        }
    }

    /// Readable color for the card's internal filename, adapting to the effective
    /// tile backdrop (light text on a dark backdrop, dark on light). None has no
    /// backdrop, so it follows the page (mood) background instead.
    private var cardNameColor: Color {
        let rgb = appState.effectiveTileBackground.backdropRGB(for: appState.moodPalette)
            ?? appState.moodPalette.backgroundRGB
        return SelectionStyle.relativeLuminance(rgb) < 0.5
            ? Color.white.opacity(0.9)
            : Color.black.opacity(0.55)
    }

    /// The native macOS icon / content preview when QuickLook has delivered it,
    /// otherwise the kind's SF Symbol as a transient fallback.
    @ViewBuilder
    private var cardIcon: some View {
        if let img = thumbnail {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: iconName(for: file.kind))
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
        }
    }

    private func iconName(for kind: AssetKind) -> String {
        switch kind {
        case .image, .raw, .psd, .svg: return "photo"
        case .pdf: return "doc.richtext"
        case .text, .markdown: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .office: return "doc.text"
        case .video: return "film"
        case .audio: return "waveform"
        case .model3d: return "cube"
        case .font: return "textformat"
        case .archive: return "archivebox"
        case .folder: return "folder"
        case .unknown: return "doc"
        }
    }
}

// MARK: - Shimmer

/// Per-mood band darkness / shoulder / overall translucency for the loading
/// sheen. Shared by the folder-enumeration skeleton AND the per-tile
/// placeholder so both shimmer identically. Tuned live (peak = band darkness,
/// shoulder = its falloff, stackOpacity = how much background tints through);
/// see docs/superpowers/assets/skeleton-shimmer-preview.html.
fileprivate func shimmerTuning(isCustom: Bool, isDark: Bool)
    -> (peak: Double, shoulder: Double, stackOpacity: Double) {
    let peak: Double, stack: Double
    if isCustom        { (peak, stack) = (0.09, 0.74) }
    else if isDark     { (peak, stack) = (0.18, 0.87) }
    else               { (peak, stack) = (0.06, 1.00) }
    return (peak, peak * 0.42, stack)
}

/// A single translucent BLACK sweep band (a soft traveling shadow, never a
/// bright streak), blurred so its gradient steps dither out. It drives its OWN
/// 0→1 sweep, so the perpetual animation lives and dies with the band — once a
/// tile's image lands and the band is removed, the animation stops (rather than
/// running forever per tile, which would pile up across the whole grid).
/// Overshoots vertically so the blur's soft edges fall outside the clipped
/// tile. The caller clips to the tile/skeleton shape.
fileprivate struct ShimmerBand: View {
    let peak: Double
    let shoulder: Double
    var blurRadius: CGFloat = 15

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let bandW = g.size.width * 0.72
            Rectangle()
                .fill(LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0),        location: 0),
                        .init(color: .black.opacity(shoulder), location: 0.38),
                        .init(color: .black.opacity(peak),     location: 0.50),
                        .init(color: .black.opacity(shoulder), location: 0.62),
                        .init(color: .black.opacity(0),        location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing))
                // Taller than the tile so the 10° tilt never exposes a corner.
                .frame(width: bandW, height: g.size.height + 120)
                .blur(radius: blurRadius)
                // Matches the prototype's `linear-gradient(100deg)` — a band
                // raked 10° off vertical rather than a straight vertical wipe.
                .rotationEffect(.degrees(10))
                .offset(x: -1.15 * bandW + phase * 2.65 * bandW, y: -60)
                // Scope the perpetual sweep to THIS band's `phase`. A global
                // withAnimation(.repeatForever) in onAppear leaks its transaction:
                // when the grid relayouts (e.g. a column-slider drag) while tiles
                // are still loading, the AppKit-hosted toolbar items get
                // repositioned in the same update cycle and SwiftUI sweeps their
                // move into this never-ending 1.8s linear animation — the trailing
                // toolbar icons then drift up/down forever (2026-06-19 toolbar-drift
                // bug). The value-scoped .animation modifier confines the repeat to
                // this subtree. Reduce Motion → no animation (the sheen stays static
                // but still reads as loading).
                .animation(reduceMotion ? nil
                           : .linear(duration: 1.8).repeatForever(autoreverses: false),
                           value: phase)
        }
        .onAppear {
            phase = reduceMotion ? 0 : 1
        }
    }
}

private extension View {
    /// Adds the folder-card management commands as named VoiceOver actions when
    /// `isFolder` is true (a no-op for file tiles, whose actions stay on the
    /// right-click `SelectionActionsMenu`). `rename` is nil when the folder can't
    /// be renamed (the iCloud root), so VoiceOver omits the action entirely
    /// rather than offering a dead one — mirroring the context menu.
    @ViewBuilder
    func folderCardActions(_ isFolder: Bool,
                           newSubfolder: @escaping () -> Void,
                           rename: (() -> Void)?,
                           reveal: @escaping () -> Void) -> some View {
        if isFolder {
            if let rename {
                self
                    .accessibilityAction(named: Text("New Subfolder")) { newSubfolder() }
                    .accessibilityAction(named: Text("Rename Folder")) { rename() }
                    .accessibilityAction(named: Text("Reveal in Finder")) { reveal() }
            } else {
                self
                    .accessibilityAction(named: Text("New Subfolder")) { newSubfolder() }
                    .accessibilityAction(named: Text("Reveal in Finder")) { reveal() }
            }
        } else {
            self
        }
    }

    /// Adds Rename as a named VoiceOver action on FILE tiles (a no-op for folder
    /// cards, which carry their own folderCardActions). Gives the mouse-only
    /// right-click Rename a keyboard/VoiceOver-reachable parallel.
    @ViewBuilder
    func fileTileActions(_ isFile: Bool, rename: @escaping () -> Void) -> some View {
        if isFile {
            self.accessibilityAction(named: Text("Rename")) { rename() }
        } else {
            self
        }
    }
}
