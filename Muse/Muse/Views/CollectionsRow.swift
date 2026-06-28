//
//  CollectionsRow.swift
//  Muse
//
//  The in-collection header that sits above the filtered grid: back arrow
//  out of the filter, editable name, count, delete. The all-collections
//  browsing surface now lives on its own page (CollectionsPage), reached
//  via the toolbar's collections icon — not an inline row here.
//

import SwiftUI
import AppKit

struct CollectionsRow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var engine = CollectionsEngine.shared

    var body: some View {
        if let activeID = appState.activeCollectionID,
           let active = engine.collections.first(where: { $0.collection.id == activeID }) {
            // Inside a collection: header with back arrow out of the filter,
            // editable name, count, delete.
            ActiveCollectionHeader(loaded: active)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 48)
                .transition(.opacity)
        }
    }
}

/// In-collection header: back arrow, title (tap or the "Edit" pill opens the
/// shared rename modal — same dialog as the sidebar + menu-bar, mirroring
/// folder rename), member count, and delete with a confirmation alert.
private struct ActiveCollectionHeader: View {
    @EnvironmentObject var appState: AppState
    let loaded: CollectionStore.Loaded

    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 18) {
            BackArrowButton { appState.setActiveCollection(nil) }
            Text(loaded.collection.name)
                .font(.system(size: 42, weight: .semibold))
                .onTapGesture { requestRename() }
            Text("\(loaded.aliveCount)")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)
            EditPill { requestRename() }
            Spacer()
            ShareCollectionButton(title: loaded.collection.name, count: loaded.aliveCount)
            TrashButton { confirmDelete = true }
        }
        // Menu-bar "Delete Collection…" routes through this flag. (Rename now
        // opens the shared modal via collectionRenameAlertRequest, not inline.)
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

    /// Open the shared rename modal seeded with this collection (the same
    /// CollectionRenameAlertRequest the sidebar + menu-bar use).
    private func requestRename() {
        appState.collectionRenameAlertRequest = CollectionRenameAlertRequest(
            id: loaded.collection.id, currentName: loaded.collection.name)
    }

    private func deleteCollection() {
        let id = loaded.collection.id
        Task { @MainActor in
            appState.setActiveCollection(nil)
            if let q = Database.shared.dbQueue {
                // Durable delete: marks the collection so the auto-organizer
                // never rebuilds it. A plain row-delete would silently come
                // back on the next analyze (it's auto-generated). No "Hide"
                // surface — from the user's side it's simply deleted.
                try? await CollectionStore.setHidden(queue: q, id: id, hidden: true)
                await CollectionsEngine.shared.reload()
            }
        }
    }
}

/// Small pill that reads "Edit"; opens the collection rename modal.
private struct EditPill: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Edit")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(.primary.opacity(hovering ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Rename collection")
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
        .accessibilityLabel("Delete collection")
    }
}

/// Circular hover-brightening back arrow, shared by the active-collection
/// header and the Collections page.
struct BackArrowButton: View {
    var help: String = String(localized: "Back to all collections")
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
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Collection card

/// Cover card for a single collection; a tap activates its filter.
struct CollectionCard: View {
    @EnvironmentObject var appState: AppState
    let loaded: CollectionStore.Loaded

    /// Cover size (a single cover image). Defaults to the compact size; the
    /// Collections page passes a width computed to fit 4 per row.
    var coverSize: CGSize = CollectionCard.defaultCoverSize

    /// Compact default cover.
    static let defaultCoverSize = CGSize(width: 240, height: 120)

    @State private var hovering = false
    @State private var confirmDelete = false

    private var isActive: Bool {
        appState.activeCollectionID == loaded.collection.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CollectionCover(collectionID: loaded.collection.id,
                            memberIDs: loaded.memberIDs,
                            coverFileID: loaded.coverFileID,
                            isEmpty: loaded.aliveCount == 0,
                            size: coverSize)
                // Hairline outline that follows the mood ("Auto") — a faint
                // iconColor line (black on light moods, white on dark) so it
                // adapts to the background instead of a fixed grey. Animated in
                // lockstep with the background fade, like the toolbar icons.
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(appState.moodPalette.iconColor.opacity(0.05), lineWidth: 1)
                )
                .animation(.easeInOut(duration: 0.35), value: appState.moodPalette)
                // Calm dark veil on hover, same as the grid tiles — no resize.
                // Suppressed on the active card (its accent border is the cue).
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black)
                        .opacity((hovering && !isActive) ? 0.2 : 0)
                        .allowsHitTesting(false)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isActive ? Color.accentColor : Color.clear,
                            lineWidth: 2
                        )
                )
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
        .frame(width: coverSize.width, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.setActiveCollection(loaded.collection.id)
        }
        .contextMenu {
            Button("Delete Collection…", role: .destructive) {
                confirmDelete = true
            }
        }
        .alert("Delete “\(loaded.collection.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteCollection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The collection is removed everywhere. Your images stay on disk.")
        }
        .help(loaded.collection.name)
        // The card is a tap target (not a Button), so VoiceOver saw two loose
        // texts with no action. Collapse it into one activatable element: name +
        // count as the label, the active card announced as selected, the tap as
        // the primary action, and the context-menu Delete re-exposed as a named
        // action (otherwise unreachable without a right-click).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(loaded.collection.name), \(loaded.aliveCount) "
                            + (loaded.aliveCount == 1 ? String(localized: "item") : String(localized: "items")))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { appState.setActiveCollection(loaded.collection.id) }
        .accessibilityAction(named: "Delete Collection") { confirmDelete = true }
    }

    private func deleteCollection() {
        let id = loaded.collection.id
        Task { @MainActor in
            if appState.activeCollectionID == id {
                appState.setActiveCollection(nil)
            }
            if let q = Database.shared.dbQueue {
                // Durable delete (see ActiveCollectionHeader.deleteCollection):
                // marks it so the auto-organizer never rebuilds it. No "Hide".
                try? await CollectionStore.setHidden(queue: q, id: id, hidden: true)
                await CollectionsEngine.shared.reload()
            }
        }
    }
}

// MARK: - Cover (single image)

private struct CollectionCover: View {
    @EnvironmentObject var appState: AppState
    let collectionID: String
    let memberIDs: [String]
    let coverFileID: String?
    /// No alive members → render a plain grey card (nothing to preview).
    var isEmpty: Bool = false
    let size: CGSize

    @State private var cover: NSImage?

    /// Fill the card, then zoom a touch *past* the fit so the side that would
    /// otherwise sit edge-to-edge gets cropped too — screenshots often carry a
    /// thin white border, and this lets the actual content define the edges.
    private let contentZoom: CGFloat = 1.10

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
            if let cover {
                Image(nsImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(contentZoom)
                    .transition(.opacity)
            } else if !isEmpty {
                // Placeholder glyph only while a non-empty collection's cover
                // loads. An empty collection stays plain grey — nothing to show.
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
        }
        // Cover fades in once loaded rather than snapping in.
        .animation(.easeOut(duration: 0.3), value: cover != nil)
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // Reload when the membership OR the chosen cover changes.
        .task(id: "\(memberIDs.joined(separator: ","))|\(coverFileID ?? "")") {
            await loadCover()
        }
    }

    private func loadCover() async {
        // An empty collection has no cover to load — leave it plain grey. Clear any
        // previously-loaded cover too: the card instance persists across engine
        // reloads (keyed by collection id), so a collection that shrinks to empty
        // would otherwise keep showing its old thumbnail.
        guard !isEmpty else { cover = nil; return }
        guard let q = Database.shared.dbQueue else { return }
        // Prefer the user-chosen cover (if still an alive member); otherwise
        // fall back to the first alive member.
        var path: String?
        if let coverFileID {
            path = try? await CollectionStore.coverPath(
                queue: q, collectionID: collectionID, coverFileID: coverFileID)
        }
        if path == nil {
            path = (try? await CollectionStore.alivePaths(
                queue: q, collectionID: collectionID, limit: 1))?.first
        }
        guard let path else { cover = nil; return }
        let url = URL(fileURLWithPath: path)
        // 320 matches the grid/viewer probe size, so the bitmap is
        // already in the shared cache.
        cover = await ThumbnailCache.shared.thumbnail(
            for: url, size: CGSize(width: 320, height: 320)
        )
    }
}

