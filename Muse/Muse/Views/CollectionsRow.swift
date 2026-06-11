//
//  CollectionsRow.swift
//  Muse
//
//  Featured collections row above the grid (Cosmos-style cover cards).
//  Top 4 collections as 3-thumb mosaic cards + an "All (⌘K)" card that
//  opens the collections overlay. Card tap filters the grid to the
//  collection's members; right-click hides the collection.
//

import SwiftUI
import AppKit
import GRDB

struct CollectionsRow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var engine = CollectionsEngine.shared

    var body: some View {
        if !engine.collections.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("COLLECTIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                HStack(spacing: 12) {
                    ForEach(engine.collections.prefix(4), id: \.collection.id) { loaded in
                        CollectionCard(loaded: loaded)
                    }
                    AllCollectionsCard(count: engine.collections.count)
                        .onTapGesture { appState.collectionsOverlayVisible = true }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Collection card

/// Cover card for a single collection. Internal so the ⌘K overlay can
/// reuse it. By default a tap activates the collection filter; pass
/// `onSelect` to override (e.g. the overlay selects AND dismisses).
struct CollectionCard: View {
    @EnvironmentObject var appState: AppState
    let loaded: CollectionStore.Loaded
    var onSelect: (() -> Void)? = nil

    private var isActive: Bool {
        appState.activeCollectionID == loaded.collection.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CollectionMosaic(collectionID: loaded.collection.id)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isActive ? Color.accentColor : Color.clear,
                            lineWidth: 2
                        )
                )
            Text(loaded.collection.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(loaded.memberIDs.count) images")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(width: 168, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if let onSelect {
                onSelect()
            } else {
                appState.setActiveCollection(loaded.collection.id)
            }
        }
        .contextMenu {
            Button("Hide Collection") {
                let id = loaded.collection.id
                Task { @MainActor in
                    if let q = Database.shared.dbQueue {
                        try? await CollectionStore.setHidden(queue: q, id: id, hidden: true)
                    }
                    if appState.activeCollectionID == id {
                        appState.setActiveCollection(nil)
                    }
                    await CollectionsEngine.shared.reload()
                }
            }
        }
        .help(loaded.collection.name)
    }
}

// MARK: - Mosaic (1 big left + 2 stacked right, 168x84)

private struct CollectionMosaic: View {
    let collectionID: String

    @State private var thumbs: [NSImage] = []

    private let totalWidth: CGFloat = 168
    private let totalHeight: CGFloat = 84
    private let gap: CGFloat = 2

    var body: some View {
        let rightWidth = (totalWidth - gap) / 3          // ~55
        let leftWidth = totalWidth - gap - rightWidth    // ~111
        let rightHeight = (totalHeight - gap) / 2        // 41

        HStack(spacing: gap) {
            mosaicCell(index: 0, width: leftWidth, height: totalHeight)
            VStack(spacing: gap) {
                mosaicCell(index: 1, width: rightWidth, height: rightHeight)
                mosaicCell(index: 2, width: rightWidth, height: rightHeight)
            }
        }
        .frame(width: totalWidth, height: totalHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: collectionID) {
            await loadThumbs()
        }
    }

    @ViewBuilder
    private func mosaicCell(index: Int, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color(NSColor.controlBackgroundColor))
            if index < thumbs.count {
                Image(nsImage: thumbs[index])
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private func loadThumbs() async {
        guard let q = Database.shared.dbQueue else { return }
        let paths = (try? await CollectionStore.alivePaths(
            queue: q, collectionID: collectionID, limit: 3
        )) ?? []
        var loaded: [NSImage] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if let img = await ThumbnailCache.shared.thumbnail(
                for: url, size: CGSize(width: 168, height: 84)
            ) {
                loaded.append(img)
            }
        }
        thumbs = loaded
    }
}

// MARK: - All collections card

private struct AllCollectionsCard: View {
    let count: Int

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            Text("All (⌘K)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 84, height: 84)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .contentShape(Rectangle())
        .help("Show all collections")
    }
}
