//
//  CollectionsRow.swift
//  Muse
//
//  Featured collections row above the grid (Cosmos-style cover cards):
//  three equal cover slices, name + count on one line below. No header —
//  the cards speak for themselves. Card tap filters the grid to the
//  collection's members; right-click hides the collection.
//

import SwiftUI
import AppKit

struct CollectionsRow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var engine = CollectionsEngine.shared

    var body: some View {
        if let activeID = appState.activeCollectionID,
           let active = engine.collections.first(where: { $0.collection.id == activeID }) {
            // Inside a collection: the cards row gives way to the header —
            // back arrow out of the filter, editable name, count, delete.
            ActiveCollectionHeader(loaded: active)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 48)
                .transition(.opacity)
        } else if !engine.collections.isEmpty {
            // All collections, horizontally scrollable — no cap; with many
            // collections you swipe through the row.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 32) {
                    ForEach(engine.collections, id: \.collection.id) { loaded in
                        CollectionCard(loaded: loaded)
                    }
                }
                .padding(.horizontal, 14)
                // Vertical padding INSIDE the scroll view so the cards' drop
                // shadow isn't clipped against the scroll view's top/bottom.
                .padding(.vertical, 10)
            }
            .transition(.opacity)
        }
    }
}

/// In-collection header: back arrow, rename-in-place title (commits on
/// return or focus loss, persisted globally via CollectionStore.rename),
/// member count, and delete with a confirmation alert.
private struct ActiveCollectionHeader: View {
    @EnvironmentObject var appState: AppState
    let loaded: CollectionStore.Loaded

    @State private var editing = false
    @State private var name = ""
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 18) {
            BackArrowButton { appState.setActiveCollection(nil) }
            if editing {
                TextField("Collection name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 42, weight: .semibold))
                    .focused($nameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelEdit() }
                    .fixedSize()
                    .onAppear { nameFocused = true }
                HStack(spacing: 8) {
                    HeaderIconButton(systemName: "checkmark",
                                     help: "Save name") { commitRename() }
                    HeaderIconButton(systemName: "xmark",
                                     help: "Cancel") { cancelEdit() }
                }
            } else {
                Text(loaded.collection.name)
                    .font(.system(size: 42, weight: .semibold))
                    .onTapGesture { startEdit() }
                Text("\(loaded.aliveCount)")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.secondary)
                HeaderIconButton(systemName: "square.and.pencil",
                                 help: "Rename collection") { startEdit() }
            }
            Spacer()
            TrashButton { confirmDelete = true }
        }
        .onChange(of: loaded.collection.id) { _, _ in cancelEdit() }
        // Menu-bar Collections commands route through these flags.
        .onChange(of: appState.collectionRenameRequest) { _, requested in
            if requested {
                appState.collectionRenameRequest = false
                startEdit()
            }
        }
        .onChange(of: appState.collectionDeleteRequest) { _, requested in
            if requested {
                appState.collectionDeleteRequest = false
                confirmDelete = true
            }
        }
        .alert("Delete “\(loaded.collection.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteCollection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The collection is removed everywhere. Your images stay on disk.")
        }
    }

    private func startEdit() {
        name = loaded.collection.name
        editing = true
    }

    private func cancelEdit() {
        editing = false
        name = loaded.collection.name
    }

    private func commitRename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        guard !trimmed.isEmpty, trimmed != loaded.collection.name else { return }
        let id = loaded.collection.id
        Task { @MainActor in
            if let q = Database.shared.dbQueue {
                try? await CollectionStore.rename(queue: q, id: id, name: trimmed)
                await CollectionsEngine.shared.reload()
            }
        }
    }

    private func deleteCollection() {
        let id = loaded.collection.id
        Task { @MainActor in
            appState.setActiveCollection(nil)
            if let q = Database.shared.dbQueue {
                try? await CollectionStore.delete(queue: q, id: id)
                await CollectionsEngine.shared.reload()
            }
        }
    }
}

/// Mid-size circular icon button for the header's edit controls.
private struct HeaderIconButton: View {
    let systemName: String
    let help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.primary.opacity(hovering ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Circular hover trash button for the header; reddens on hover.
private struct TrashButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(hovering ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.primary.opacity(hovering ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Delete collection")
    }
}

/// Circular hover-brightening back arrow for the active-collection header.
private struct BackArrowButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.left")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.primary.opacity(hovering ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Back to all collections")
    }
}

// MARK: - Collection card

/// Cover card for a single collection; a tap activates its filter.
struct CollectionCard: View {
    @EnvironmentObject var appState: AppState
    let loaded: CollectionStore.Loaded

    /// Compact cover, a 2×2 grid of cells — smaller footprint so the
    /// collections read as distinct cards rather than one dense band.
    static let coverSize = CGSize(width: 240, height: 120)

    @State private var hovering = false

    private var isActive: Bool {
        appState.activeCollectionID == loaded.collection.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CollectionMosaic(collectionID: loaded.collection.id, memberIDs: loaded.memberIDs)
                // Hairline grey border + soft drop shadow so each card reads
                // as a distinct object instead of blending into the row.
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isActive ? Color.accentColor : Color.clear,
                            lineWidth: 2
                        )
                )
                .shadow(color: Color.black.opacity(0.16), radius: 6, x: 0, y: 2)
                // Same gentle lift as the grid tiles below on hover.
                .scaleEffect(hovering ? 1.025 : 1)
                .animation(.easeOut(duration: 0.18), value: hovering)
                .onHover { hovering = $0 }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(loaded.collection.name)
                    .font(.system(size: 15, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(loaded.aliveCount)")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.coverSize.width, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.setActiveCollection(loaded.collection.id)
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

// MARK: - Mosaic (2×2 cover cells)

private struct CollectionMosaic: View {
    @EnvironmentObject var appState: AppState
    let collectionID: String
    let memberIDs: [String]

    @State private var thumbs: [NSImage] = []

    // White frame around the edges + white gaps between the four images,
    // so the card reads as a white object with the photos floated inside.
    private let inset: CGFloat = 8
    private let gap: CGFloat = 6

    var body: some View {
        let size = CollectionCard.coverSize
        let cellWidth = (size.width - 2 * inset - gap) / 2
        let cellHeight = (size.height - 2 * inset - gap) / 2

        VStack(spacing: gap) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<2, id: \.self) { col in
                        mosaicCell(index: row * 2 + col,
                                   width: cellWidth, height: cellHeight)
                    }
                }
            }
        }
        .padding(inset)
        .frame(width: size.width, height: size.height)
        // Translucent rather than solid white, so the card picks up a hint of
        // the mood background behind it — like the tag chips.
        .background(Color.white.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: memberIDs) {
            await loadThumbs()
        }
    }

    @ViewBuilder
    private func mosaicCell(index: Int, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
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
            queue: q, collectionID: collectionID, limit: 4
        )) ?? []
        var loaded: [NSImage] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            // 320 matches the grid/viewer probe size, so the bitmap is
            // already in the shared cache.
            if let img = await ThumbnailCache.shared.thumbnail(
                for: url, size: CGSize(width: 320, height: 320)
            ) {
                loaded.append(img)
            }
        }
        thumbs = loaded
    }
}

