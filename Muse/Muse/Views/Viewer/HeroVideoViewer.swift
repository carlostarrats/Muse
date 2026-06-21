//
//  HeroVideoViewer.swift
//  Muse
//
//  The hero viewer for videos: ViewerBackdrop (color wash from a sampled frame)
//  + a centered aspect-fit AVPlayerView + ViewerInfoColumn (tags/collections/
//  colors/INFO) + ViewerToast. Deliberately simpler than HeroImageViewer — no
//  zoom/pan, no flight, no arrow-key flipping. Close/Escape just clear
//  selectedFile (EscapeAction.closeViewer); the .opacity transition unmounts it.
//

import SwiftUI
import AppKit
import AVFoundation

struct HeroVideoViewer: View {
    @EnvironmentObject var appState: AppState
    let file: FileNode

    @State private var details: ViewerFileDetails?
    @State private var metadata: FileMetadata?
    @State private var naturalSize: CGSize?
    @State private var computedPalette: [String] = []
    @State private var paletteResolved = false
    @State private var backdropVisible = false
    /// The video stage fades in a beat AFTER the backdrop, so the backdrop
    /// reads as "settling first" and the large video doesn't flash up in
    /// lockstep with it (there's no flight to bridge the tile→hero size jump).
    @State private var stageVisible = false
    @State private var chromeVisible = false
    @State private var toast: ToastData?
    @State private var deleting = false
    /// 0 = fully visible, 1 = gone (the delete fade-out).
    @State private var fade: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ViewerBackdrop(hexColor: details?.dominantColor ?? computedPalette.first)
                    .opacity(backdropVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.4), value: backdropVisible)
                    .contentShape(Rectangle())
                    .onTapGesture { close() }

                stage(viewport: geo.size)
                rightRail
                ViewerToast(toast: $toast)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(1 - fade)
        }
        .ignoresSafeArea()
        .onAppear {
            backdropVisible = true   // leads — fades in over its own 0.4s
            // Video lags the backdrop, then eases in gently (no flash-up).
            withAnimation(.easeOut(duration: 0.35).delay(0.22)) { stageVisible = true }
            withAnimation(.easeOut(duration: 0.4).delay(0.15)) { chromeVisible = true }
        }
        .task(id: file.url) { await loadDetails() }
        // Reload tag/collection pills when tags mutate library-wide.
        .onChange(of: appState.tagsVersion) { _, _ in
            Task { await loadDetails() }
        }
    }

    // MARK: - Stage

    private func stage(viewport: CGSize) -> some View {
        let size = naturalSize ?? CGSize(width: 16, height: 9)
        let rect = ViewerGeometry.fitRect(imageSize: size, viewport: viewport)
        return VideoPlayerView(url: file.url)
            .frame(width: rect.width, height: rect.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
            .position(x: rect.midX, y: rect.midY)
            .opacity(stageVisible ? 1 : 0)
    }

    // MARK: - Right rail

    private var rightRail: some View {
        ViewerInfoColumn(url: file.url,
                         details: details,
                         fallbackPalette: computedPalette,
                         paletteLoading: !paletteResolved,
                         metadata: metadata,
                         backing: .black,
                         backingVisible: false,
                         refresh: { await loadDetails() },
                         onTagTap: { label in
                             appState.searchQuery = label
                             Task { await appState.runSearch(label) }
                             close()
                         },
                         onCollectionTap: { id in
                             appState.setActiveCollection(id)
                             close()
                         },
                         onOpenInFinder: {
                             NSWorkspace.shared.activateFileViewerSelecting([file.url])
                         },
                         onDelete: deleteCurrent,
                         toast: $toast,
                         chrome: { chromeRow })
            .contentShape(Rectangle())
            .onTapGesture {}
            .padding(.top, 20)
            .padding(.bottom, 28)
            .padding(.trailing, ViewerGeometry.columnMargin - 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible && !deleting)
    }

    private var chromeRow: some View {
        HStack(spacing: 8) {
            Spacer()
            ShareButton(url: file.url)
            VideoCloseButton(action: close)
        }
        .frame(width: ViewerGeometry.columnWidth)
    }

    // MARK: - Close

    private func close() {
        guard !deleting else { return }
        // Drop the grid selection so closing leaves nothing selected (parity
        // with the hero image close), then unmount via the .opacity transition.
        appState.clearSelection()
        appState.selectedFile = nil
    }

    // MARK: - Delete / undo

    private func deleteCurrent() {
        guard !deleting else { return }
        deleting = true
        let url = file.url
        let node = appState.currentFiles.first { $0.url == url }
        withAnimation(.easeInOut(duration: 0.35)) { fade = 1 }
        Task {
            try? await Task.sleep(nanoseconds: 380_000_000)
            await completeDelete(url: url, node: node)
        }
    }

    private func completeDelete(url: URL, node: FileNode?) async {
        do {
            let ticket = try await TrashManager.trash(url)
            withAnimation(.easeIn(duration: 0.2)) {
                appState.currentFiles.removeAll { $0.url == url }
            }
            // Hand the Undo toast to the always-present GridToastHost so it
            // survives the viewer unmount.
            appState.deletion.toast = ToastData(message: "Moved to Trash",
                                                actionLabel: "Undo") {
                appState.deletion.restore(ticket: ticket,
                                          node: node ?? FileNode(url: url))
            }
            appState.selectedFile = nil
            appState.clearSelection()
        } catch {
            withAnimation(.easeOut(duration: 0.18)) {
                toast = ToastData(message: "Couldn't move to Trash")
                fade = 0
                deleting = false
            }
        }
    }

    // MARK: - Load

    private func loadDetails() async {
        let url = file.url
        // Kick off the frame palette now so swatches/backdrop land while the
        // chrome fades in.
        async let quick = HeroPalette.videoPalette(at: url)
        var loaded: ViewerFileDetails? = nil
        if let queue = Database.shared.dbQueue {
            loaded = try? await ViewerFileDetails.load(queue: queue, path: url.path)
        }
        details = loaded
        metadata = await FileMetadata.load(url: url, kind: .video)
        if naturalSize == nil {
            naturalSize = await Self.videoNaturalSize(at: url)
        }
        if let palette = loaded?.palette, !palette.isEmpty {
            paletteResolved = true
        } else {
            let pal = await quick
            withAnimation(.easeOut(duration: 0.25)) {
                computedPalette = pal
                paletteResolved = true
            }
        }
    }

    /// The video's display size (natural size with the preferred transform
    /// applied), used for the aspect-fit stage rect. nil → caller's 16:9 default.
    nonisolated private static func videoNaturalSize(at url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let applied = size.applying(transform)
        let w = abs(applied.width), h = abs(applied.height)
        guard w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }
}

/// 38pt circular close button (the ✕), hover-brightening — the only chrome
/// control the video viewer needs (no zoom pill / Fit).
private struct VideoCloseButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1.0 : 0.85))
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(hovering ? 0.24 : 0.10)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
        .onHover { hovering = $0 }
    }
}
