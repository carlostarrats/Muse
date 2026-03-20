//
//  GridView.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI
import AppKit

// MARK: - GridView

struct GridView: View {

    @EnvironmentObject var appState: AppState

    /// Asynchronously loaded thumbnails keyed by image ID.
    @State private var thumbnailCache: [UUID: NSImage] = [:]

    /// Current mouse position in the grid's coordinate space, normalised to [-1, 1].
    @State private var normalisedCursor: CGPoint = .zero

    var body: some View {
        GeometryReader { geometry in
            let columnCount = columns(for: geometry.size.width)

            ScrollView {
                MasonryLayout(columns: columnCount, spacing: 12) {
                    ForEach(appState.filteredImages) { image in
                        let isSelected = appState.selectedImages.contains(image.id)
                        TileView(
                            image: image,
                            thumbnail: thumbnailCache[image.id],
                            isSelected: isSelected
                        )
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) {
                                appState.selectedImage = nil
                                appState.toggleImageSelection(image)
                                appState.detailPanelVisible = !appState.selectedImages.isEmpty
                            } else {
                                appState.selectedImages.removeAll()
                                appState.selectedImage = image
                                appState.detailPanelVisible = true
                            }
                        }
                        .onAppear {
                            loadThumbnail(for: image)
                        }
                    }
                }
                .padding(20)
            }
            // Global parallax tilt on cursor movement
            .rotation3DEffect(
                .degrees(normalisedCursor.y * 2.5),
                axis: (x: 1, y: 0, z: 0)
            )
            .rotation3DEffect(
                .degrees(normalisedCursor.x * 2.5),
                axis: (x: 0, y: 1, z: 0)
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    withAnimation(.easeOut(duration: 0.15)) {
                        normalisedCursor = normalise(location, in: geometry.size)
                    }
                case .ended:
                    withAnimation(.easeOut(duration: 0.3)) {
                        normalisedCursor = .zero
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func columns(for width: CGFloat) -> Int {
        if width < 800 { return 3 }
        if width > 1400 { return 5 }
        return 4
    }

    private func normalise(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        let x = (point.x / size.width) * 2 - 1
        let y = (point.y / size.height) * 2 - 1
        return CGPoint(x: x, y: y)
    }

    private func loadThumbnail(for image: MuseImage) {
        guard thumbnailCache[image.id] == nil else { return }
        guard let url = image.resolvedThumbnailURL else { return }

        Task.detached(priority: .utility) {
            guard let loaded = NSImage(contentsOf: url) else { return }
            await MainActor.run {
                thumbnailCache[image.id] = loaded
            }
        }
    }
}

// MARK: - TileView

private struct TileView: View {

    let image: MuseImage
    let thumbnail: NSImage?
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        tileContent
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                // Only show border on multi-selected images
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(isHovered ? 0.2 : 0.08), radius: isHovered ? 5 : 2, x: 0, y: 1)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.18), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }

    @ViewBuilder
    private var tileContent: some View {
        if let nsImage = thumbnail {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
        } else {
            let ratio: CGFloat = {
                if let w = image.width, let h = image.height, w > 0 {
                    return CGFloat(w) / CGFloat(h)
                }
                return 1.0
            }()
            Color(NSColor.systemGray)
                .opacity(0.3)
                .aspectRatio(ratio, contentMode: .fit)
        }
    }
}
