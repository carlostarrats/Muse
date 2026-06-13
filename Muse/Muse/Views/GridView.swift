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

    private let spacing: CGFloat = 10
    private let contentInset: CGFloat = 20
    @State private var addTagFile: FileNode? = nil
    @State private var newTagText = ""
    /// User-set images-per-row, persisted; the bottom-right slider drives it.
    @AppStorage("gridColumnCount") private var gridColumns = 4

    @StateObject private var aspects = AspectRatioCache()

    // Precomputed layout (recomputed only when the file set, column count,
    // width, or resolved aspect ratios change — never on scroll).
    @State private var frames: [CGRect] = []
    @State private var totalHeight: CGFloat = 0
    @State private var layoutWidth: CGFloat = 0

    /// The masonry canvas's top, in the scroll viewport's coordinate space.
    /// 0 at the top; goes negative as the user scrolls down.
    @State private var canvasMinY: CGFloat = 0

    /// Drives the skeleton placeholder's gentle pulse while a folder loads.
    @State private var skeletonPulse = false

    var body: some View {
        GeometryReader { geo in
            let contentWidth = max(0, geo.size.width - contentInset * 2)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
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
            .background(appState.moodPalette.background)
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
            .coordinateSpace(name: "gridViewport")
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
            ForEach(visibleIndices(lo: lo, hi: hi, count: files.count), id: \.self) { i in
                let rect = frames[i]
                let file = files[i]
                TileView(file: file, order: i, deletion: appState.deletion)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    // Single tap only — the old double-tap recognizer made every
                    // click wait out the double-click interval before the viewer
                    // opened. Editing flows live in the Open With… context menu.
                    .onTapGesture {
                        appState.selectedFile = file
                    }
                    .contextMenu {
                        OpenWithMenu(url: file.url)
                        Divider()
                        Button("Add Tag…") {
                            newTagText = ""
                            addTagFile = file
                        }
                        Divider()
                        Button("Move to Trash", role: .destructive) {
                            Task { await appState.deletion.deleteWithBurn(file) }
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
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .help("Images per row")
    }

    /// Pulsing placeholder tiles shown the instant a folder is selected,
    /// while its contents enumerate off-main — so clicking a folder feels
    /// immediate instead of a frozen pause followed by a sudden pop-in.
    private func skeletonGrid(width: CGFloat) -> some View {
        // Varied heights evoke the jigsaw without needing real dimensions.
        let ratios: [CGFloat] = [1.3, 0.8, 1.0, 1.5, 0.7, 1.15, 0.9, 1.25]
        let cols = max(1, gridColumns)
        let columnWidth = max(1, (width - CGFloat(cols - 1) * spacing) / CGFloat(cols))
        return HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<cols, id: \.self) { col in
                VStack(spacing: spacing) {
                    ForEach(0..<5, id: \.self) { row in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(appState.moodPalette.tileFill)
                            .frame(height: columnWidth * ratios[(col * 5 + row) % ratios.count])
                    }
                }
                .frame(width: columnWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(contentInset)
        .opacity(skeletonPulse ? 0.45 : 0.85)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                skeletonPulse = true
            }
        }
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
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }

    private var emptyStateMessage: String? {
        if appState.selectedFolder == nil {
            return "Select a folder"
        }
        if appState.activeCollectionID != nil {
            return "No collection members in this folder"
        }
        return nil   // genuinely empty folder → blank
    }
}

private struct TileView: View {
    @EnvironmentObject var appState: AppState
    let file: FileNode
    /// Visual position in the grid — thumbnail loads are served in this
    /// order, so a cold folder fills top-to-bottom.
    var order: Int = 0
    @ObservedObject var deletion: DeleteCoordinator

    @State private var thumbnail: NSImage?
    @State private var tileFrame: CGRect = .zero
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
                if appState.selectedFile?.id == file.id {
                    RoundedRectangle(cornerRadius: isImageKind ? 0 : 8,
                                     style: .continuous)
                        .stroke(Color.accentColor.opacity(0.8), lineWidth: 2)
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
                        .onAppear {
                            tileFrame = proxy.frame(in: .named("gridViewport"))
                            appState.tileFrames[file.url.path] = proxy.frame(in: .global)
                        }
                        .onChange(of: proxy.frame(in: .named("gridViewport"))) { _, newFrame in
                            tileFrame = newFrame
                        }
                        .onChange(of: proxy.frame(in: .global)) { _, f in
                            appState.tileFrames[file.url.path] = f
                        }
                }
            )
            .modifier(BurnUpModifier(
                progress: deletion.burningPaths.contains(file.url.path) ? 1 : 0,
                seed: Double(SeededRandom.fnv1a([file.url.path]) % 1000) / 1000.0,
                size: tileFrame.size))
            .task(id: file.url) {
                // 320 matches the hero viewer's first cache probe, so the open
                // flight starts from this exact bitmap with zero wait.
                thumbnail = await ThumbnailCache.shared.thumbnail(
                    for: file.url,
                    size: CGSize(width: 320, height: 320),
                    order: order
                )
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
