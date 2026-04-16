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
                MasonryLayout(columns: columnCount, spacing: 20) {
                    ForEach(appState.filteredImages) { image in
                        let isSelected = appState.selectedImages.contains(image.id)
                        TileView(
                            image: image,
                            thumbnail: thumbnailCache[image.id],
                            isSelected: isSelected,
                            dispImage: appState.fluidDispImage,
                            viewportSize: geometry.size
                        )
                        .overlay(
                            ClickHandlerView(
                                onSingleClick: {
                                    if NSEvent.modifierFlags.contains(.command) {
                                        appState.selectedImage = nil
                                        appState.toggleImageSelection(image)
                                        appState.detailPanelVisible = !appState.selectedImages.isEmpty
                                    } else {
                                        appState.selectedImages.removeAll()
                                        appState.selectedImages.insert(image.id)
                                        appState.selectedImage = nil
                                        appState.detailPanelVisible = false
                                    }
                                },
                                onDoubleClick: {
                                    appState.selectedImages.removeAll()
                                    appState.selectedImage = image
                                    appState.detailPanelVisible = true
                                }
                            )
                        )
                        .onAppear {
                            loadThumbnail(for: image)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(NSColor.windowBackgroundColor))
            // Global parallax tilt on cursor movement — subtle and smooth
            .rotation3DEffect(
                .degrees(normalisedCursor.y * 1.2),
                axis: (x: 1, y: 0, z: 0)
            )
            .rotation3DEffect(
                .degrees(normalisedCursor.x * 1.2),
                axis: (x: 0, y: 1, z: 0)
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    appState.fluidSim.setMouse(location)
                    withAnimation(.interactiveSpring(response: 0.6, dampingFraction: 0.7)) {
                        normalisedCursor = normalise(location, in: geometry.size)
                    }
                case .ended:
                    appState.fluidSim.clearMouse()
                    withAnimation(.interactiveSpring(response: 0.8, dampingFraction: 0.6)) {
                        normalisedCursor = .zero
                    }
                }
            }
            .onChange(of: geometry.size) { _, newSize in
                appState.fluidSim.viewportSize = newSize
            }
            .onAppear {
                appState.fluidSim.viewportSize = geometry.size
            }
            .coordinateSpace(name: "gridViewport")
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
        // Prefer full-res image for grid quality, fall back to thumbnail
        let url = image.resolvedStorageURL ?? image.resolvedThumbnailURL
        guard let url else { return }

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
    let dispImage: Image
    let viewportSize: CGSize

    @State private var isHovered = false
    @State private var tileFrame: CGRect = .zero

    private static let limeGreen = Color(red: 0.2, green: 1.0, blue: 0.0)

    var body: some View {
        tileContent
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Self.limeGreen : Color.clear, lineWidth: 2)
            )
            .shadow(color: isSelected ? Self.limeGreen.opacity(0.6) : .black.opacity(0.12), radius: isSelected ? 12 : 6, x: 0, y: isSelected ? 0 : 3)
            .shadow(color: .black.opacity(isHovered ? 0.1 : 0), radius: 10, x: 0, y: 5)
            .layerEffect(
                ShaderLibrary.fluidDistort(
                    .image(dispImage),
                    .float2(Float(tileFrame.minX), Float(tileFrame.minY)),
                    .float2(Float(viewportSize.width), Float(viewportSize.height))
                ),
                maxSampleOffset: CGSize(width: 50, height: 50)
            )
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { tileFrame = geo.frame(in: .named("gridViewport")) }
                    .onChange(of: geo.frame(in: .named("gridViewport"))) { _, newFrame in
                        tileFrame = newFrame
                    }
            })
            .animation(.easeOut(duration: 0.18), value: isHovered)
            .animation(.easeOut(duration: 0.18), value: isSelected)
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
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .animation(.easeOut(duration: 0.3), value: isHovered)
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

// MARK: - ClickHandlerView

/// An NSView-backed click handler that fires single and double clicks instantly
/// without the SwiftUI gesture disambiguation delay.
private struct ClickHandlerView: NSViewRepresentable {
    var onSingleClick: () -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ClickNSView {
        let view = ClickNSView()
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: ClickNSView, context: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }
}

private class ClickNSView: NSView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onSingleClick?()
        }
    }
}
