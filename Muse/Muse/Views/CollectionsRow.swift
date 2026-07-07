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

    /// Pile cell size. Defaults to the compact size; the Collections page
    /// passes a width computed to fit 4 per row.
    var coverSize: CGSize = CollectionCard.defaultCoverSize

    /// Compact default pile cell — the square-ish aspect the stack needs
    /// (matches the Collections page's cardWidth × 0.9), not the old 2:1
    /// cover rectangle.
    static let defaultCoverSize = CGSize(width: 240, height: 216)

    @State private var hovering = false
    @State private var confirmDelete = false
    /// Keeps the pile above its neighbors while the settle-back spring is
    /// still in flight (zIndex isn't animatable — dropping it the instant
    /// the cursor leaves would dip retracting cards under the next pile).
    @State private var elevated = false
    @State private var elevationToken = 0

    private var isActive: Bool {
        appState.activeCollectionID == loaded.collection.id
    }

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            CollectionStackCard(collectionID: loaded.collection.id,
                                memberIDs: loaded.memberIDs,
                                coverFileID: loaded.coverFileID,
                                isEmpty: loaded.aliveCount == 0,
                                size: coverSize,
                                fanned: hovering,
                                isActive: isActive)
                // Fan out fast with a visible spring overshoot; settle back a
                // touch slower and calmer — matches the reference video.
                .onHover { h in
                    withAnimation(h ? .spring(response: 0.38, dampingFraction: 0.62)
                                    : .spring(response: 0.45, dampingFraction: 0.8)) {
                        hovering = h
                    }
                    elevationToken += 1
                    if h {
                        elevated = true
                    } else {
                        let token = elevationToken
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            if elevationToken == token { elevated = false }
                        }
                    }
                }
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
        .frame(width: coverSize.width, alignment: .center)
        .zIndex(elevated ? 10 : 0)
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

// MARK: - Stack (scattered pile, fans on hover)

/// The pile of member images that replaces the old single cropped cover:
/// up to `depth` cards at their natural aspect ratios, cover on top, loose
/// deterministic scatter at rest (seeded by the collection id via
/// StackScatter), fanned apart while `fanned` is true. Cards are not hit-
/// testable — the pile's cell rect is the hover/tap target, so the fan
/// spilling over neighbors never steals their clicks and the hover region
/// doesn't grow (no retract flicker at the edges).
private struct CollectionStackCard: View {
    let collectionID: String
    let memberIDs: [String]
    let coverFileID: String?
    /// No alive members → render a plain grey card (nothing to preview).
    var isEmpty: Bool = false
    let size: CGSize
    let fanned: Bool
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cards: [NSImage] = []

    /// Pile depth — matches the reference video's ~6-card piles.
    static let depth = 6

    var body: some View {
        let box = min(size.width, size.height) * 0.78
        let poses = StackScatter.cards(seed: collectionID,
                                       count: cards.count, cell: size)
        ZStack {
            if cards.isEmpty {
                // Plain grey card: the whole state for an empty collection,
                // a placeholder while a non-empty one's thumbnails load.
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: box, height: box * 0.75)
                if !isEmpty {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
            } else {
                // ZStack draws first-child bottom-most; cards[0] is the TOP
                // card, so mount deepest cards first.
                ForEach(Array(cards.indices.reversed()), id: \.self) { i in
                    card(cards[i],
                         pose: (fanned && !reduceMotion) ? poses[i].fan : poses[i].rest,
                         box: box,
                         isTop: i == 0)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        // Pile fades in once thumbnails land rather than snapping in.
        .animation(.easeOut(duration: 0.3), value: cards.isEmpty)
        // Reload when the membership OR the chosen cover changes.
        .task(id: "\(memberIDs.joined(separator: ","))|\(coverFileID ?? "")") {
            await loadStack()
        }
    }

    @ViewBuilder
    private func card(_ image: NSImage, pose: StackScatter.Pose,
                      box: CGFloat, isTop: Bool) -> some View {
        let s = StackScatter.fit(imageSize: image.size, box: box)
        Image(nsImage: image)
            .resizable()
            .frame(width: s.width, height: s.height)
            // Reduce Motion: no fan — the old calm veil on the top card is
            // the hover cue instead.
            .overlay(
                Rectangle()
                    .fill(Color.black)
                    .opacity((isTop && reduceMotion && fanned && !isActive) ? 0.2 : 0)
            )
            .overlay(
                Rectangle()
                    .strokeBorder(
                        (isTop && isActive) ? Color.accentColor : Color.clear,
                        lineWidth: 2
                    )
            )
            .shadow(color: .black.opacity(0.12), radius: 9, x: 0, y: 3)
            .scaleEffect(pose.scale)
            .rotationEffect(.degrees(pose.rotationDegrees))
            .offset(x: pose.offset.width, y: pose.offset.height)
            .allowsHitTesting(false)
    }

    private func loadStack() async {
        // An empty collection has no pile to load — stay plain grey. Clear any
        // previously-loaded cards too: the card instance persists across engine
        // reloads (keyed by collection id), so a collection that shrinks to
        // empty would otherwise keep showing its old pile.
        guard !isEmpty else { cards = []; return }
        guard let q = Database.shared.dbQueue else { return }
        // The user-chosen cover leads the pile (if still an alive member);
        // the next members in order fill the rest, repeating when short.
        var cover: String?
        if let coverFileID {
            cover = try? await CollectionStore.coverPath(
                queue: q, collectionID: collectionID, coverFileID: coverFileID)
        }
        // depth + 1: room to dedupe the cover out of the member page.
        let members = (try? await CollectionStore.alivePaths(
            queue: q, collectionID: collectionID, limit: Self.depth + 1)) ?? []
        let paths = StackScatter.stackPaths(cover: cover, members: members,
                                            depth: Self.depth)
        // Load each UNIQUE path once, then reference the shared bitmap for
        // repeats — a collection with fewer images than the pile depth stacks
        // members more than once, so `paths` carries duplicates. 320 matches
        // the grid/viewer probe size, so these already sit in the shared cache.
        var byPath: [String: NSImage] = [:]
        for path in Set(paths) {
            let url = URL(fileURLWithPath: path)
            if let img = await ThumbnailCache.shared.thumbnail(
                for: url, size: CGSize(width: 320, height: 320)) {
                byPath[path] = img
            }
        }
        // Reassemble in pile order (cover first), dropping any that failed.
        cards = paths.compactMap { byPath[$0] }
    }
}

