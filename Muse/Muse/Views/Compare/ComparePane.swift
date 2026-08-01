//
//  ComparePane.swift
//  Muse
//
//  One decode ladder per pane: the cached grid thumbnail instantly, then a
//  bounded sharp decode at hero-class target size. `withinDecodeBudget` runs
//  first — this is an automatic (no-click) full-raster decode site like every
//  other one.
//

import SwiftUI

struct ComparePane: View {
    let url: URL
    let isFocused: Bool
    let mark: SharpnessRank.SharpnessMark
    let bestFaceQuality: Bool
    @ObservedObject var store: CompareStore
    @ObservedObject var cull: CullStore

    @State private var sharpImage: CGImage?
    @State private var imageSize: CGSize = .zero

    /// Pane decodes ask for roughly 2.5× the pane's long edge (retina plus
    /// headroom for zooming in), clamped to a sane band.
    private static let scaleFactor: CGFloat = 2.5
    private static let minTarget = 1600
    private static let maxTarget = 4096

    var body: some View {
        GeometryReader { geo in
            let rect = CompareGeometry.drawRect(imageSize: imageSize, paneSize: geo.size,
                                                zoom: store.zoom, center: store.center)
            ZStack {
                Color.black.opacity(0.35)
                if let sharpImage, rect != .zero {
                    Image(decorative: sharpImage, scale: 1)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .overlay {
                            if store.peaking {
                                PeakingOverlayView(source: sharpImage, accent: .accentColor)
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                                    .allowsHitTesting(false)
                            }
                        }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(alignment: .bottomLeading) { badges }
            .overlay {
                if isFocused {
                    Rectangle().stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .task(id: url) { await loadLadder(paneSize: geo.size) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(paneAccessibilityLabel)
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 4) {
            switch mark {
            case .sharpest:
                Image(systemName: "diamond.fill")
                    .foregroundStyle(.green)
                    .help(String(localized: "Sharpest of the compared photos"))
            case .softer:
                Image(systemName: "diamond")
                    .foregroundStyle(.orange)
                    .help(String(localized: "Softer than the sharpest here"))
            case .comparable, .unmarked:
                EmptyView()
            }
            if bestFaceQuality {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(.green)
                    .help(String(localized: "Best face capture quality here"))
            }
            if cull.active, let m = cull.mark(for: url.standardizedFileURL.path) {
                Image(systemName: m == .keep ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(m == .keep ? .green : .red)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(6)
    }

    private var paneAccessibilityLabel: String {
        var parts = [url.lastPathComponent]
        switch mark {
        case .sharpest: parts.append(String(localized: "sharpest here"))
        case .softer:   parts.append(String(localized: "softer here"))
        default: break
        }
        if cull.active, let m = cull.mark(for: url.standardizedFileURL.path) {
            parts.append(m == .keep ? String(localized: "kept") : String(localized: "rejected"))
        }
        return parts.joined(separator: ", ")
    }

    private func loadLadder(paneSize: CGSize) async {
        sharpImage = nil
        imageSize = .zero
        let target = min(max(Int(max(paneSize.width, paneSize.height) * Self.scaleFactor),
                             Self.minTarget), Self.maxTarget)
        let fileURL = url
        // Decodes the ORIGINAL directly rather than going through
        // ThumbnailCache — a pane-sized variant would have to be enumerated in
        // `renderedVariants` or it would survive an in-place edit forever.
        //
        // An edited file renders its stack here, exactly as the grid tile and
        // the hero do (DECISIONS' Spec-04 forward note: compare panes MUST
        // join the edit-render sweep). Without it, comparing two edited photos
        // showed the unedited originals — the one surface where that matters
        // most, since compare exists to judge them against each other.
        // `boundedDecode` is the budget gate for the fallback; the render path
        // gets the same gate below.
        let stack = EditStackIndex.resolvedStack(for: fileURL)
        let decoded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            if let stack,
               let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
               ThumbnailCache.withinDecodeBudget(src),
               let rendered = EditRenderer.render(url: fileURL, stack: stack, maxPixel: target) {
                return rendered
            }
            return VisionServices.boundedDecode(url: fileURL, maxPixel: target)
        }.value
        guard !Task.isCancelled, fileURL == url, let decoded else { return }
        imageSize = CGSize(width: decoded.width, height: decoded.height)
        sharpImage = decoded
    }
}
