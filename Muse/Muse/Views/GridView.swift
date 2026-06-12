//
//  GridView.swift
//  Muse
//
//  Phase 0.5 grid driven by FileNode. Lazy-loads thumbnails via
//  ThumbnailCache. Shows a kind-specific icon for non-image kinds when
//  the thumbnail is missing or still generating.
//

import SwiftUI
import AppKit

struct GridView: View {
    @EnvironmentObject var appState: AppState

    private let spacing: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
        ScrollView {
            if appState.visibleFiles.isEmpty {
                emptyState
            } else {
                // Jigsaw pack: images keep their own aspect ratio and stack
                // into the shortest column — no identical squares, no
                // letterboxing dead space.
                MasonryLayout(columns: columnCount(for: geo.size.width),
                              spacing: spacing) {
                    ForEach(appState.visibleFiles) { file in
                        TileView(file: file, deletion: appState.deletion)
                            // Single tap only — the old double-tap recognizer
                            // (open in default app) made every single click wait
                            // out the double-click interval before the viewer
                            // opened, and spawning Preview was never approved.
                            // Editing flows live in the Open With… context menu.
                            .onTapGesture {
                                appState.selectedFile = file
                            }
                            .contextMenu {
                                OpenWithMenu(url: file.url)
                                Divider()
                                Button("Move to Trash", role: .destructive) {
                                    Task { await appState.deletion.deleteWithBurn(file) }
                                }
                            }
                            .transition(.scale(scale: 0.1).combined(with: .opacity))
                    }
                }
                .padding(20)
            }
        }
        .background(appState.moodPalette.background)
        .animation(.easeInOut(duration: 0.35), value: appState.moodPalette)
        .coordinateSpace(name: "gridViewport")
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                if appState.fluidEnabled {
                    appState.fluidSim.setMouse(location)
                    appState.fluidSim.viewportSize = geo.size
                    appState.fluidViewportSize = geo.size
                }
            case .ended:
                appState.fluidSim.clearMouse()
            }
        }
        .onChange(of: geo.size) { _, newSize in
            appState.fluidSim.viewportSize = newSize
            appState.fluidViewportSize = newSize
        }
        .onAppear {
            appState.fluidSim.viewportSize = geo.size
            appState.fluidViewportSize = geo.size
        }
        }
    }

    /// Wider window → more columns; columns stay in the 220–320pt band.
    private func columnCount(for width: CGFloat) -> Int {
        max(2, Int((width - 40) / 260))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(appState.selectedFolder == nil
                 ? "Select a folder"
                 : appState.activeCollectionID != nil
                 ? "No collection members in this folder"
                 : "Empty folder")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct TileView: View {
    @EnvironmentObject var appState: AppState
    let file: FileNode
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
            .applyIf(appState.fluidEnabled && (file.kind == .image || file.kind == .raw || file.kind == .psd)) { view in
                view.layerEffect(
                    ShaderLibrary.fluidDistort(
                        .image(appState.fluidDispImage),
                        .float2(Float(tileFrame.minX), Float(tileFrame.minY)),
                        .float2(Float(appState.fluidViewportSize.width),
                                Float(appState.fluidViewportSize.height))
                    ),
                    maxSampleOffset: CGSize(width: 50, height: 50)
                )
            }
            .modifier(BurnUpModifier(
                progress: deletion.burningPaths.contains(file.url.path) ? 1 : 0,
                seed: Double(SeededRandom.fnv1a([file.url.path]) % 1000) / 1000.0,
                size: tileFrame.size))
            .task(id: file.url) {
                // 320 matches the hero viewer's first cache probe, so the open
                // flight starts from this exact bitmap with zero wait.
                thumbnail = await ThumbnailCache.shared.thumbnail(
                    for: file.url,
                    size: CGSize(width: 320, height: 320)
                )
            }
    }

    /// Images: natural aspect, column-width, edge to edge (the jigsaw piece).
    /// Other kinds: a compact labeled card so files stay identifiable.
    @ViewBuilder
    private var tile: some View {
        if isImageKind, let img = thumbnail {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if isImageKind {
            // Aspect placeholder until the thumbnail lands.
            Rectangle()
                .fill(appState.moodPalette.tileFill)
                .aspectRatio(1, contentMode: .fit)
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
            .frame(maxWidth: .infinity)
            .aspectRatio(1.4, contentMode: .fit)
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

// MARK: - View helper

private extension View {
    @ViewBuilder
    func applyIf<R: View>(_ condition: Bool, transform: (Self) -> R) -> some View {
        if condition { transform(self) } else { self }
    }
}
