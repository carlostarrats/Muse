//
//  SidebarView.swift
//  Muse
//
//  Multi-root folder tree (Q1, Q26). Roots are listed as top-level items;
//  each is a lazy-loading hierarchical tree. Clicking a folder selects it as
//  the active folder (Q2 Adobe Bridge style); the chevron expands/collapses
//  to reveal subfolders. Styled after Lineform's custom file browser —
//  chevron disclosure, folder icons, and rounded hover fills — rather than a
//  native List, so rows get consistent hover feedback.
//

import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    /// The root currently being dragged for manual reordering.
    @State private var draggingRoot: Root?
    /// Insertion index (into the reorderable roots) the drop would land at.
    @State private var dropTarget: Int?
    /// Physical row index currently under the cursor — guards exit-clear so a
    /// neighbour that just claimed the target isn't wiped.
    @State private var dropOwner: Int?

    /// Height of a single collapsed folder row; the drop midpoint for the
    /// before/after split lives at half this.
    fileprivate static let rowHeight: CGFloat = 28

    /// Low-opacity fill used behind a hovered row, matching Lineform.
    static let rowHoverFillOpacity = 0.08

    /// Opaque card surface (Lineform's near-white / dark values) so the
    /// sidebar reads as one continuous card rather than a translucent panel.
    private var cardColor: Color {
        Color(nsColor: NSColor(
            calibratedWhite: colorScheme == .dark ? 0.18 : 0.988, alpha: 1
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            if appState.rootNodes.isEmpty && appState.stars.starred.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        // The iCloud "Muse" folder is the fixed home — always on
                        // top, not reorderable — with a gap below it separating
                        // it from the local folders.
                        if let icloud = iCloudNode {
                            FolderTreeNode(node: icloud, depth: 0)
                            Color.clear.frame(height: 12)
                        }

                        if !appState.stars.starred.isEmpty {
                            ForEach(appState.stars.starred) { star in
                                StarRow(star: star)
                            }
                        }

                        ForEach(Array(reorderableNodes.enumerated()),
                                id: \.element.id) { pair in
                            rootRow(pair.element, index: pair.offset)
                        }
                        // Catch-area below the last folder so a drag released in
                        // the empty space underneath still lands at the bottom.
                        if !reorderableNodes.isEmpty { endDropZone }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                }
                .scrollContentBackground(.hidden)
            }

            AddFolderPillButton { appState.pickAndAddRoot() }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 220)
        // One continuous card: the opaque surface flows up behind the title
        // bar and curves with the window's top corner, like Lineform.
        .background(cardColor.ignoresSafeArea())
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("No files imported yet.")
                .font(.system(size: 13, weight: .semibold))
            Text("Get Started.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    /// The bookmark Root backing a top-level node, if it's a user folder that
    /// can be reordered (the iCloud "Muse" folder has no bookmark, so nil).
    private func reorderableRoot(for node: FolderNode) -> Root? {
        appState.bookmarks.roots.first { appState.bookmarks.url(for: $0) == node.url }
    }

    /// Top-level nodes that can be dragged to reorder (everything but iCloud).
    private var reorderableNodes: [FolderNode] {
        appState.rootNodes.filter { reorderableRoot(for: $0) != nil }
    }

    /// The non-reorderable iCloud "Muse" node, if signed in.
    private var iCloudNode: FolderNode? {
        appState.rootNodes.first { reorderableRoot(for: $0) == nil }
    }

    /// A thin accent rule shown where a dragged folder will land.
    private var insertionLine: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 6)
    }

    /// One draggable top-level folder. The drop line is an overlay (not a real
    /// row) so showing it never shifts layout — which would make the row under
    /// the cursor jump and the drag target flicker. Hovering the top half of a
    /// row targets the gap above it; the bottom half targets the gap below — so
    /// dragging a folder onto another's lower half drops it underneath.
    @ViewBuilder
    private func rootRow(_ node: FolderNode, index: Int) -> some View {
        if let model = reorderableRoot(for: node) {
            FolderTreeNode(node: node, depth: 0)
                .opacity(draggingRoot == model ? 0.4 : 1)
                .overlay(alignment: .top) {
                    if draggingRoot != nil, dropTarget == index { insertionLine }
                }
                .onDrag {
                    draggingRoot = model
                    dropTarget = nil
                    dropOwner = nil
                    return NSItemProvider(object: model.id.uuidString as NSString)
                }
                .onDrop(of: [.text],
                        delegate: RootDropDelegate(index: index,
                                                   splitHeight: Self.rowHeight,
                                                   store: appState.bookmarks,
                                                   dragging: $draggingRoot,
                                                   dropTarget: $dropTarget,
                                                   dropOwner: $dropOwner))
        } else {
            FolderTreeNode(node: node, depth: 0)
        }
    }

    /// Drop area filling the space under the last folder. Always targets the
    /// end, and shows the landing line at its top edge (just below the last
    /// folder) so dragging "to the bottom" reliably lands there.
    private var endDropZone: some View {
        ZStack(alignment: .top) {
            Color.clear.frame(height: 44)
            if draggingRoot != nil, dropTarget == reorderableNodes.count {
                insertionLine
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [.text],
                delegate: RootDropDelegate(index: reorderableNodes.count,
                                           splitHeight: nil,
                                           store: appState.bookmarks,
                                           dragging: $draggingRoot,
                                           dropTarget: $dropTarget,
                                           dropOwner: $dropOwner))
    }
}

// MARK: - Root drag-to-reorder

/// Tracks the insertion point as a folder is dragged and commits the move on
/// release. The cursor's vertical position within the row picks the gap: top
/// half → before this row (`index`), bottom half → after it (`index + 1`), so
/// the last row's bottom half targets the very end.
private struct RootDropDelegate: DropDelegate {
    let index: Int
    /// Row height for the before/after split; nil for the end zone, which
    /// always targets `index` (the end).
    let splitHeight: CGFloat?
    let store: BookmarkStore
    @Binding var dragging: Root?
    @Binding var dropTarget: Int?
    @Binding var dropOwner: Int?

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard dragging != nil else { return nil }
        dropOwner = index
        let newTarget = splitHeight.map { info.location.y > $0 / 2 ? index + 1 : index } ?? index
        if newTarget != dropTarget { dropTarget = newTarget }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // Clear only if this row still owns the target — a neighbour we've
        // already crossed into may have claimed it (its dropTarget can equal
        // ours when both point at the gap between us).
        if dropOwner == index {
            dropOwner = nil
            dropTarget = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil; dropTarget = nil; dropOwner = nil }
        guard let dragging, let dest = dropTarget,
              let from = store.roots.firstIndex(of: dragging) else { return false }
        withAnimation(.easeInOut(duration: 0.18)) {
            store.move(from: from, to: dest)
        }
        return true
    }
}

// MARK: - Folder tree node

/// One folder row plus its (lazily loaded) subfolders. Tapping the label
/// selects the folder; tapping the chevron expands/collapses it.
private struct FolderTreeNode: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var node: FolderNode
    let depth: Int

    @State private var isHovered = false

    private var hasChildren: Bool { !node.children.isEmpty }

    private var isSelected: Bool { appState.selectedFolder?.id == node.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row
            if node.isExpanded {
                ForEach(node.children) { child in
                    FolderTreeNode(node: child, depth: depth + 1)
                }
            }
        }
        // Load one level ahead so the disclosure chevron can appear for
        // folders that actually contain subfolders.
        .onAppear { node.loadChildrenIfNeeded() }
    }

    private var row: some View {
        HStack(spacing: 8) {
            // Disclosure: a real button so it captures its own taps,
            // independent of the row's selection tap. Leaves keep an
            // invisible placeholder so labels stay aligned.
            if hasChildren {
                Button(action: toggleExpand) {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(node.isExpanded ? "Collapse" : "Expand")
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0)
                    .frame(width: 10)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 8) {
                Image(systemName: node.url == appState.iCloudFolderURL ? "icloud" : "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor)
                                                : AnyShapeStyle(.primary))
                    .frame(width: 18)

                Text(node.displayName)
                    .font(.system(size: 13, weight: node.isRoot ? .medium : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor)
                                                : AnyShapeStyle(.primary))
                    .lineLimit(1)

                Spacer(minLength: 0)

                // Small trailing indicator when the folder is pinned.
                if appState.stars.isStarred(node.url) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { appState.select(folder: node) }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowFill)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .contextMenu {
            // Pinning is a shortcut for buried subfolders; top-level folders are
            // already visible at the top of the sidebar, so Pin is offered only
            // for subfolders. Roots are reordered by dragging instead.
            if !node.isRoot {
                Button(appState.stars.isStarred(node.url) ? "Unpin" : "Pin") {
                    appState.toggleStar(folder: node)
                }
            } else if let r = appState.bookmarks.roots.first(where: {
                appState.bookmarks.url(for: $0) == node.url
            }) {
                Button("Remove Folder") { appState.removeRoot(r) }
            }
        }
    }

    private var rowFill: Color {
        if isSelected {
            return Color.accentColor.opacity(0.14)
        }
        return Color.primary.opacity(isHovered ? SidebarView.rowHoverFillOpacity : 0)
    }

    private func toggleExpand() {
        node.loadChildrenIfNeeded()
        node.isExpanded.toggle()
    }
}

// MARK: - Starred row

/// A starred-folder shortcut, styled to match the folder tree rows.
private struct StarRow: View {
    @EnvironmentObject var appState: AppState
    let star: StarStore.StarredFolder

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .opacity(0)
                .frame(width: 10)
                .accessibilityHidden(true)

            Image(systemName: "pin.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(star.displayName)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? SidebarView.rowHoverFillOpacity : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture { appState.openStarred(star) }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .contextMenu {
            Button("Unpin") {
                appState.stars.unstar(folder: URL(fileURLWithPath: star.path))
            }
        }
    }
}

// MARK: - Add Folder pill

/// Centered high-contrast pill, styled after Lineform's action buttons —
/// dark pill / light text in light mode, reversed in dark mode, with a
/// hover brighten.
private struct AddFolderPillButton: View {
    var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label("Add Folder", systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 16)
                .frame(height: 28)
        }
        .buttonStyle(.plain)
        .background {
            Capsule(style: .continuous).fill(fillColor)
        }
        .foregroundStyle(textColor)
        .frame(maxWidth: .infinity, alignment: .center)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
    }

    private var fillColor: Color {
        Color(nsColor: NSColor(calibratedWhite: usesDark
            ? (isHovered ? 1.0 : 0.92)
            : (isHovered ? 0.12 : 0.20),
            alpha: 1))
    }

    private var textColor: Color {
        Color(nsColor: NSColor(calibratedWhite: usesDark ? 0.10 : 1.0, alpha: 1))
    }

    private var usesDark: Bool { colorScheme == .dark }
}
