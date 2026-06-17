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

    /// Manual double-click detection so single-click selection is INSTANT —
    /// a lone `onTapGesture` fires immediately, with no SwiftUI count:1-vs-2
    /// disambiguation delay. A second quick tap on the same tile opens it.
    @State private var lastTapPath: String?
    @State private var lastTapAt: Date = .distantPast

    private func handleTileTap(_ file: FileNode) {
        let p = file.url.standardizedFileURL.path
        let now = Date()
        if lastTapPath == p, now.timeIntervalSince(lastTapAt) < 0.35 {
            lastTapPath = nil
            appState.selectedFile = file          // double-click → open
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
                            skeletonGrid(width: contentWidth)
                        } else {
                            emptyState
                        }
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
                            .id("\(appState.activeCollectionID ?? "")|\(appState.activeTagLabel ?? "")")
                            .transition(.opacity)
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
            .onChange(of: aspects.version) { _, _ in
                recompute(width: contentWidth)
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
                        let p = file.url.standardizedFileURL.path
                        if !appState.selectedFiles.contains(p) {
                            appState.applyClick(.single(p))
                        }
                        return NSItemProvider(object: file.url as NSURL)
                    }
                    .offset(x: rect.minX, y: rect.minY)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(file.basename)
                    // Expose selection to VoiceOver, not just via the color/border.
                    .accessibilityAddTraits(
                        appState.selectedFiles.contains(file.url.standardizedFileURL.path)
                            ? [.isButton, .isSelected] : .isButton)
                    .accessibilityHint("Double-tap to open. Right-click for actions.")
                    .contextMenu {
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
                                    if let node = byPath[url.standardizedFileURL.path] {
                                        await appState.deletion.deleteWithBurn(node)
                                    }
                                }
                            }
                        }
                    }
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
        let ratios = files.map { aspects.aspect(for: $0) }
        let result = MasonryGeometry.compute(aspects: ratios,
                                             columns: gridColumns,
                                             width: width,
                                             spacing: spacing)
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
            appState.activeTagLabel ?? "",
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
            Slider(value: Binding(
                get: { Double(gridColumns) },
                set: { gridColumns = Int($0.rounded()) }
            ), in: 2...8, step: 1)
            .frame(width: 130)
            .controlSize(.small)
            Image(systemName: "square.grid.4x3.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
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

    /// Shimmering placeholder tiles shown the instant a folder is selected,
    /// while its contents enumerate off-main — so clicking a folder feels
    /// immediate instead of a frozen pause followed by a sudden pop-in.
    private func skeletonGrid(width: CGFloat) -> some View {
        // Varied heights evoke the jigsaw without needing real dimensions.
        let ratios: [CGFloat] = [1.3, 0.8, 1.0, 1.5, 0.7, 1.15, 0.9, 1.25]
        let cols = max(1, gridColumns)
        let columnWidth = max(1, (width - CGFloat(cols - 1) * spacing) / CGFloat(cols))

        // Inverted, mood-aware sweep: a translucent BLACK band (a soft shadow)
        // travels through each tile — never a bright streak. It's blurred so the
        // gradient steps dither out (no banding), and the whole stack is drawn
        // below 1 opacity so a colored background tints through. Per-mood shadow
        // strength + stack opacity were tuned live (skeleton-shimmer-preview.html).
        let palette = appState.moodPalette
        let tuning = shimmerTuning(isCustom: appState.mood == .custom,
                                   isDark: palette.scheme == .dark)

        return HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<cols, id: \.self) { col in
                VStack(spacing: spacing) {
                    ForEach(0..<5, id: \.self) { row in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(palette.tileFill)
                            .overlay {
                                ShimmerBand(peak: tuning.peak,
                                            shoulder: tuning.shoulder)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .frame(height: columnWidth * ratios[(col * 5 + row) % ratios.count])
                    }
                }
                .frame(width: columnWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(contentInset)
        .opacity(tuning.stackOpacity)
        .transition(.opacity)
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

private struct TileView: View {
    @EnvironmentObject var appState: AppState
    let file: FileNode
    /// Visual position in the grid — thumbnail loads are served in this
    /// order, so a cold folder fills top-to-bottom.
    var order: Int = 0
    @ObservedObject var deletion: DeleteCoordinator
    /// Reports the decoded thumbnail's exact aspect back to the layout so the
    /// tile frame matches the image (no grey letterbox).
    var reportAspect: (CGFloat) -> Void = { _ in }

    @State private var thumbnail: NSImage?
    @State private var hovering = false

    private var isImageKind: Bool {
        file.kind == .image || file.kind == .raw || file.kind == .psd || file.kind == .svg
    }

    var body: some View {
        tile
            // Images sit square-cornered (edge-to-edge jigsaw pieces); only
            // the non-image file cards keep the rounded card look.
            .clipShape(RoundedRectangle(cornerRadius: isImageKind ? 0 : 8,
                                        style: .continuous))
            .overlay {
                // Selected (multi-select) OR the open file get an accent wash
                // + border. Inside the scaleEffect below, so they grow with the
                // hover zoom instead of the image spilling past them. The tint
                // tracks the system accent (light blue by default).
                if appState.selectedFiles.contains(file.url.standardizedFileURL.path)
                    || appState.selectedFile?.id == file.id {
                    RoundedRectangle(cornerRadius: isImageKind ? 0 : 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.22))
                        .overlay {
                            RoundedRectangle(cornerRadius: isImageKind ? 0 : 8, style: .continuous)
                                .stroke(Color.accentColor, lineWidth: 3)
                        }
                }
            }
            .scaleEffect(hovering ? 1.025 : 1)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
            // Prototype's hidden-cell: the tile vanishes while its image is
            // flying/open so no ghost copy sits behind the hero stage.
            .opacity(appState.selectedFile?.url == file.url ? 0 : 1)
            // Never animated: the restore must land in the same frame the
            // hero unmounts — ContentView's 0.18s selectedFile animation
            // otherwise fades the tile back in, a visible blink after the
            // close flight lands.
            .animation(nil, value: appState.selectedFile?.url)
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
            // Delete = a quiet fade-out (no burn/fire shader). The coordinator
            // marks the path, the tile fades to 0, then it's removed and the
            // grid closes the gap.
            .opacity(deletion.burningPaths.contains(file.url.path) ? 0 : 1)
            .animation(.easeOut(duration: 0.3),
                       value: deletion.burningPaths.contains(file.url.path))
            .task(id: file.url) {
                // 320 matches the hero viewer's first cache probe, so the open
                // flight starts from this exact bitmap with zero wait.
                // Retry on nil so a tile never stays grey: ImageIO carries the
                // image path reliably, but the QuickLook fallback (PDF, SVG,
                // fonts…) can transiently fail under load — a short backoff
                // recovers it instead of leaving a dead box.
                for attempt in 0..<4 {
                    if let img = await ThumbnailCache.shared.thumbnail(
                        for: file.url,
                        size: CGSize(width: 320, height: 320),
                        order: order
                    ) {
                        // Correct the tile's aspect from the real image BEFORE
                        // showing it, so the frame is already right when the
                        // image lands — it fills, never letterboxed in grey.
                        // Image kinds only: non-image cards keep their fixed
                        // labeled-card aspect (a QuickLook doc thumbnail's
                        // proportions must not resize the card).
                        if isImageKind, img.size.width > 0 {
                            reportAspect(img.size.height / img.size.width)
                        }
                        thumbnail = img
                        return
                    }
                    if Task.isCancelled { return }
                    // No backoff after the final attempt — it would just stall
                    // a permanently-unrenderable tile for nothing.
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: UInt64(300_000_000) * UInt64(attempt + 1))
                    }
                }
            }
    }

    /// Images: natural aspect, fitted into the precomputed jigsaw frame.
    /// Other kinds: a compact labeled card so files stay identifiable.
    @ViewBuilder
    private var tile: some View {
        if isImageKind {
            // Placeholder stays put; the decoded image fades IN over it when
            // it lands, so a cold grid resolves as a soft fade rather than
            // hard tiles snapping in top-to-bottom.
            ZStack {
                Rectangle()
                    .fill(appState.moodPalette.tileFill)
                // While the thumbnail generates, the grey placeholder sweeps
                // with the same loading sheen as the folder skeleton — so any
                // grey a user sees is alive, never a dead box. Removed the
                // instant the image lands.
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
            VStack(spacing: 8) {
                Image(systemName: iconName(for: file.kind))
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text(file.basename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(appState.moodPalette.tileFill))
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
        }
        .onAppear {
            phase = 0
            // Reduce Motion: leave the sheen static (still reads as loading).
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}
