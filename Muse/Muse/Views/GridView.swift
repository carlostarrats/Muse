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

    private let spacing: CGFloat = 14
    private let contentInset: CGFloat = 20
    @State private var addTagFile: FileNode? = nil
    @State private var newTagText = ""
    /// User-set images-per-row, persisted; the bottom-right slider drives it.
    @AppStorage("gridColumnCount") private var gridColumns = 4
    /// Off-by-default: show each file's name under its tile.
    @AppStorage(AppSettings.showFileNamesKey) private var showFileNames = false
    /// Fixed under-tile caption strip height (one line of `.caption`), constant
    /// across column counts — matches the collection-PDF export's fixed caption.
    private let captionStripHeight: CGFloat = 18

    /// The caption height actually reserved this render (0 when names are off).
    private var effectiveCaptionHeight: CGFloat {
        showFileNames ? captionStripHeight : 0
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
                    // Page Up / Page Down scrolls the grid a screenful at a
                    // time. Inactive while a hero viewer covers the grid.
                    PageScrollCatcher(isActive: { appState.selectedFile == nil })
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
                            emptyState
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
                            // one clean cross-fade, not a per-tile reflow.
                            .id("\(appState.activeCollectionID ?? "")|\(appState.activeTagLabels.joined(separator: "\u{1f}"))")
                            .transition(.opacity)
                    }
                }
                }
            }
            .coordinateSpace(name: "gridScroll")
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
                TileView(file: file, order: i, deletion: appState.deletion,
                         showFileNames: showFileNames,
                         captionHeight: effectiveCaptionHeight,
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
                    .offset(x: rect.minX, y: rect.minY)
                    .accessibilityElement(children: .ignore)
                    // Folder cards have only an icon on screen — name the kind so
                    // VoiceOver disambiguates a folder from a file.
                    .accessibilityLabel(file.kind == .folder
                                        ? String(localized: "\(file.basename), folder") : file.basename)
                    // Expose selection to VoiceOver, not just via the color/border.
                    .accessibilityAddTraits(
                        appState.selectedFiles.contains(file.url.standardizedFileURL.path)
                            ? [.isButton, .isSelected] : .isButton)
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

    @ViewBuilder
    private var emptyState: some View {
        // A plain empty folder shows nothing — just blank space. Only the
        // states that need guidance (no folder picked, or a collection filter
        // with no members here) get a message.
        if let message = emptyStateMessage {
            VStack(spacing: 14) {
                Image(systemName: "tray")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }

    private var emptyStateMessage: String? {
        // Inside a collection, an empty result shows nothing — no icon, no
        // message, just blank space under the header (the header already
        // names the collection).
        if appState.activeCollectionID != nil {
            return nil
        }
        // No folder picked → blank space, never a "Select a folder" tray prompt.
        return nil
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
        // Prototype's hidden-cell: the tile vanishes while its image is
        // flying/open so no ghost copy sits behind the hero stage.
        .opacity(appState.selectedFile?.url == file.url ? 0 : 1)
        // Never animated: the restore must land in the same frame the hero
        // unmounts (see the close-flight note in the original code).
        .animation(nil, value: appState.selectedFile?.url)
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

            // Hover veil — unselected tiles only; a calm dark wash, no resize.
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
}
