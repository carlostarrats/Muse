//
//  FolderTreeNode.swift
//  Muse
//
//  One folder row in the sidebar tree (disclosure, hover fill, drag grip).
//  Extracted verbatim from SidebarView.swift in the 2026-06-20 code-health
//  refactor (file moves only; `private` types became internal so they can live
//  in their own files). Behavior unchanged.
//

import SwiftUI
import AppKit

// MARK: - Folder tree node

/// One folder row plus its (lazily loaded) subfolders. Tapping the label
/// selects the folder; tapping the chevron expands/collapses it.
struct FolderTreeNode: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.sidebarReordering) private var isReordering
    @ObservedObject var node: FolderNode
    let depth: Int
    /// Toggle-scoped file count to show at the trailing edge (top-level rows
    /// only); nil for subfolders or before the stat is computed.
    var topLevelCount: Int? = nil
    /// Non-nil only for reorderable top-level folders: supplies the reorder drag
    /// gesture handlers for the trailing grip. nil for subfolders + the iCloud
    /// home (not reorderable).
    var reorder: ReorderContext? = nil

    @State private var isHovered = false
    /// True while grid images are being dragged over this folder.
    @State private var dropTargeted = false

    private var hasChildren: Bool { !node.children.isEmpty }

    private var isSelected: Bool {
        // Cross-folder views have no "current" folder, so hide the highlight:
        // the Collections page, a single collection, and a library-wide ("All")
        // search. A "This folder" search keeps the highlight — the folder IS the
        // scope. `selectedFolder` itself is untouched, so Back/clear restores it.
        if appState.showingCollections || appState.activeCollectionID != nil {
            return false
        }
        if appState.isSearchActive && appState.searchAllFolders { return false }
        return appState.selectedFolder?.url.standardizedFileURL
            == node.url.standardizedFileURL
    }

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

    /// The app-managed iCloud "Muse" root with nothing in it (recursively empty).
    /// Selecting it would just show a blank grid, so it's presented as
    /// non-interactive — dimmed, no selection tap — until it actually holds files.
    /// A nil stat (count not computed yet) stays clickable so a still-loading
    /// folder isn't wrongly disabled.
    private var isEmptyICloudRoot: Bool {
        node.url == appState.iCloudFolderURL
            && appState.folderStats.stat(for: node.url)?.recursiveFileCount == 0
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
                .accessibilityLabel(node.isExpanded ? String(localized: "Collapse") : String(localized: "Expand"))
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
                    .truncationMode(.tail)

                // Keep a gap so a long name truncates with an ellipsis before it
                // reaches the pin / reorder grip rather than running into them.
                Spacer(minLength: 6)

                // Small trailing indicator when the folder is pinned.
                if appState.stars.isStarred(node.url) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                // Trailing slot: the file count, which swaps in place for the
                // drag grip on hover (Manual mode only — `reorder` is non-nil only
                // then). During a drag the grip is shown via the floating overlay,
                // so in-list rows fall back to the count.
                if topLevelCount != nil || reorder != nil {
                    let showGrip = reorder != nil && isHovered && !isReordering
                    ZStack(alignment: .trailing) {
                        if let topLevelCount {
                            Text("\(topLevelCount)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .opacity(showGrip ? 0 : 1)
                        }
                        if let reorder {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 22)
                                .opacity(showGrip ? 1 : 0)
                                .contentShape(Rectangle())
                                .allowsHitTesting(isHovered || isReordering)
                                .highPriorityGesture(
                                    DragGesture(minimumDistance: 3,
                                                coordinateSpace: .named(SidebarView.reorderSpace))
                                        .onChanged { reorder.onChanged($0) }
                                        .onEnded { reorder.onEnded($0) }
                                )
                                .onTapGesture { appState.select(folder: node) }
                                .help("Drag to reorder")
                                // Mouse-only drag affordance; its tap just
                                // re-selects the row (already reachable) and the
                                // accessible reorder path is the Edit-menu Move
                                // Folder Up/Down. Exposing an undraggable "grip"
                                // to VoiceOver would only add a dead control.
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            // Dim an empty iCloud "Muse" root so it reads as non-interactive.
            .opacity(isEmptyICloudRoot ? 0.4 : 1)
            .contentShape(Rectangle())
            // Plain tap-to-select on the row label. Reliable because the only drag
            // source (the grip) is an isolated AppKit view, not a SwiftUI .onDrag
            // on this hosting view (see SidebarView.rootRow). No-op when the row is
            // an empty iCloud root (nothing to show).
            .onTapGesture { if !isEmptyICloudRoot { appState.select(folder: node) } }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(dropTargeted ? Color.accentColor.opacity(0.22) : rowFill)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
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
                // Keyboard/VoiceOver-accessible parallel to drag-to-reorder
                // (the grip is mouse-only). `reorder != nil` means this is a
                // reorderable root in Manual sort — the sorted modes are
                // read-only, so Move Up/Down only appears then.
                if reorder != nil {
                    // Index into the DISPLAYED roots (resolved bookmarks only),
                    // matching the drag path — a root whose bookmark didn't
                    // resolve is hidden from the sidebar, so indexing the full
                    // bookmarks.roots could make a move appear to do nothing.
                    let list = appState.rootNodes.compactMap { n in
                        appState.bookmarks.roots.first {
                            appState.bookmarks.url(for: $0) == n.url
                        }
                    }
                    let idx = list.firstIndex(of: r)
                    Button("Move Up") {
                        if let i = idx, i > 0 {
                            appState.bookmarks.reorder(r, relativeTo: list[i - 1],
                                                       placeAfter: false)
                        }
                    }
                    .disabled((idx ?? 0) <= 0)
                    Button("Move Down") {
                        if let i = idx, i < list.count - 1 {
                            appState.bookmarks.reorder(r, relativeTo: list[i + 1],
                                                       placeAfter: true)
                        }
                    }
                    .disabled(idx == nil || idx! >= list.count - 1)
                    Divider()
                }
                Button("Remove Folder") { appState.removeRoot(r) }
            }
            Divider()
            Button("New Subfolder…") { appState.requestNewSubfolder(node) }
            // The iCloud "Muse" home is app-managed — not renamable.
            if node.url != appState.iCloudFolderURL {
                Button("Rename Folder…") { appState.requestRenameFolder(node) }
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
        }
        // Drop grid images here to move them into this folder. The grid's
        // .onDrag selects the dragged tile first, so the current selection is
        // the set to move. (Reorder is a separate live gesture, no .onDrop, so
        // there's no drop-type shadowing here anymore.)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { _ in
            // Move only files — a folder in the selection stays put (no
            // folder drag-to-move in v1; a folder tile's own .onDrag is a
            // no-op, but a folder co-selected with files would otherwise ride
            // along when a file tile is dragged onto a sidebar folder).
            let selected = appState.effectiveSelectionURLs(fallback: "").filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
            }
            guard !selected.isEmpty else { return false }
            appState.reloadAfterMove(failed: FileMover.move(selected, into: node.url))
            return true
        }
    }

    private var rowFill: Color {
        if isSelected {
            return Color.accentColor.opacity(0.14)
        }
        // Suppress the hover fill while a reorder drag is passing over rows.
        let showHover = isHovered && !isReordering
        return Color.primary.opacity(showHover ? SidebarView.rowHoverFillOpacity : 0)
    }

    private func toggleExpand() {
        node.loadChildrenIfNeeded()
        node.isExpanded.toggle()
    }
}

