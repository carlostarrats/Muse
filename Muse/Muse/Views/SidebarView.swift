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
import AppKit

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    /// Active top-level folder sort mode. Lives on AppState (persisted via
    /// AppSettings there) so the Edit-menu Move Up/Down items share one
    /// reactive source with the sidebar.
    private var sortMode: FolderSortMode { appState.folderSortMode }

    /// The root currently being dragged for manual reordering (live gesture).
    @State private var draggingRoot: Root?
    /// Insertion slot (0...count) the dragged folder would land at; drives the line.
    @State private var dropTarget: Int?
    /// Live vertical offset of the dragged row so the real row follows the cursor.
    @State private var dragOffset: CGFloat = 0
    /// Each reorderable root row's frame in `reorderSpace`.
    @State private var rootFrames: [UUID: CGRect] = [:]
    /// Snapshot of `rootFrames` taken when a drag begins. Used for ALL slot math
    /// during the drag because live frames move once rows are offset to part —
    /// reading them back would feed back into the computation.
    @State private var dragStartFrames: [UUID: CGRect] = [:]

    /// Height of a single collapsed folder row.
    fileprivate static let rowHeight: CGFloat = 28
    /// Named coordinate space shared by the reorder drag gesture and the row
    /// frame measurements, so the two are always compared in the same space.
    fileprivate static let reorderSpace = "sidebarReorder"

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
                sortHeader
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        // The iCloud "Muse" folder is the fixed home — always on
                        // top, not reorderable — with a gap below it separating
                        // it from the local folders.
                        if let icloud = iCloudNode {
                            FolderTreeNode(node: icloud, depth: 0,
                                           topLevelCount: topLevelCount(for: icloud))
                            Color.clear.frame(height: 12)
                        }

                        if !appState.stars.starred.isEmpty {
                            ForEach(appState.stars.starred) { star in
                                StarRow(star: star)
                            }
                        }

                        ForEach(Array(displayedReorderableNodes.enumerated()),
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
                .coordinateSpace(name: Self.reorderSpace)
                .onPreferenceChange(RootFramePreference.self) { rootFrames = $0 }
                .environment(\.sidebarReordering, draggingRoot != nil)
                // Safety net: if the dragged root disappears mid-drag (removed
                // elsewhere, or its node rebuilt) the gesture's .onEnded may never
                // fire, which would otherwise strand the sidebar in drag state
                // (rows parted, hover/grip suppressed, overlay drawn).
                .onChange(of: reorderableNodes.map(\.id)) { _, _ in
                    if draggingRoot != nil, draggedIndex == nil { resetDrag() }
                }
                // Backup insertion line (helps when you overshoot the gap).
                .overlay(alignment: .top) {
                    if draggingRoot != nil, let y = insertionLineY() {
                        insertionLine.offset(y: y - 1).allowsHitTesting(false)
                    }
                }
                // Opaque floating copy of the dragged row, on top of everything.
                .overlay(alignment: .top) {
                    if let dragging = draggingRoot, let f = dragStartFrames[dragging.id] {
                        draggedRowOverlay(dragging)
                            .offset(y: f.minY + dragOffset)
                            .allowsHitTesting(false)
                    }
                }
            }

            AddFolderPillButton { appState.pickAndAddRoot() }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 220)
        // One continuous card: the opaque surface flows up behind the title
        // bar and curves with the window's top corner, like Lineform.
        // Tapping the empty sidebar surface deselects the grid (folder rows and
        // the add button consume their own taps).
        .background {
            cardColor.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { appState.clearSelection() }
        }
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

    // MARK: - Sort header

    private var sortHeader: some View {
        HStack {
            Menu {
                ForEach(FolderSortMode.allCases) { mode in
                    Button { setSortMode(mode) } label: {
                        if sortMode == mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Sort: \(sortMode.label)")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func setSortMode(_ mode: FolderSortMode) {
        // AppState persists to AppSettings via its sink; just publish the change.
        withAnimation(.easeInOut(duration: 0.2)) { appState.folderSortMode = mode }
    }

    /// Top-level rows in display order: BookmarkStore order for Manual, otherwise
    /// the comparator over name + cached stat.
    private var displayedReorderableNodes: [FolderNode] {
        let nodes = reorderableNodes
        guard sortMode != .manual else { return nodes }
        let items = nodes.map {
            FolderSort.Item(id: $0.id, name: $0.displayName,
                            stat: appState.folderStats.stat(for: $0.url))
        }
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return FolderSort.order(items, by: sortMode).compactMap { byId[$0] }
    }

    /// The toggle-scoped count to display for a top-level folder, or nil if its
    /// stat hasn't been computed yet.
    private func topLevelCount(for node: FolderNode) -> Int? {
        guard let stat = appState.folderStats.stat(for: node.url) else { return nil }
        return appState.showSubfolders ? stat.recursiveFileCount : stat.immediateFileCount
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

    /// A thin accent rule shown at the gap where the folder will land — a backup
    /// cue if you overshoot. Inset to line up with the row backgrounds.
    private var insertionLine: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 14)
    }

    /// Y (from the ScrollView top) of the gap at `dropTarget`. Uses LIVE frames
    /// (which reflect the parting offsets) so the line sits at the open gap.
    private func insertionLineY() -> CGFloat? {
        guard let target = dropTarget else { return nil }
        let others = otherReorderRoots
        guard !others.isEmpty else { return nil }
        if target >= others.count {
            return others.last.flatMap { rootFrames[$0.id]?.maxY }
        }
        return rootFrames[others[target].id]?.minY
    }

    /// An opaque copy of the dragged folder row, drawn as a ScrollView overlay so
    /// it stays above every row it passes (LazyVStack ignores zIndex). Mirrors the
    /// real row's metrics so it lands seamlessly.
    private func draggedRowOverlay(_ root: Root) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right").opacity(0).frame(width: 10)
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18)
            Text(root.displayName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 6)
            // Keep the grabber with the row while it moves.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 22)
        }
        .padding(.horizontal, 6)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(cardColor))
        .scaleEffect(1.02)
        .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
        .padding(.horizontal, 8)
    }

    /// The reorderable roots EXCLUDING the one being dragged. The dragged row is
    /// conceptually lifted out, so insertion happens among these "other" rows.
    private var otherReorderRoots: [Root] {
        reorderableNodes
            .compactMap { reorderableRoot(for: $0) }
            .filter { $0.id != draggingRoot?.id }
    }

    /// The dragged folder's index in the full reorderable list.
    private var draggedIndex: Int? {
        guard let dragging = draggingRoot else { return nil }
        return reorderableNodes.firstIndex { reorderableRoot(for: $0)?.id == dragging.id }
    }

    /// How far a NON-dragged row at full index `i` should slide to part and open
    /// a gap for the dragged row at `dropTarget` (an index into the others). Rows
    /// below the dragged one rise to close its hole; rows at/after the target sink
    /// to open the gap. Uses the drag-start snapshot's height so it's stable.
    private func rowShift(forIndex i: Int) -> CGFloat {
        guard let d = draggedIndex, let target = dropTarget, i != d else { return 0 }
        let pitch = (draggingRoot.flatMap { dragStartFrames[$0.id]?.height }
                     ?? Self.rowHeight) + 1   // + LazyVStack spacing
        let removedIndex = i < d ? i : i - 1
        var shift: CGFloat = 0
        if i > d { shift -= pitch }                 // close the dragged row's hole
        if removedIndex >= target { shift += pitch } // open the gap at the target
        return shift
    }

    /// One draggable top-level folder. Reorder is a LIVE gesture, not pasteboard
    /// drag-and-drop: the trailing grip drives a DragGesture; the dragged row is
    /// hidden in place (so its slot stays and the others can part around it) while
    /// an opaque copy (`draggedRowOverlay`) follows the cursor on top — LazyVStack
    /// ignores zIndex, so a top overlay is the reliable way to keep it above the
    /// rows it passes. A faint insertion line marks the gap as an overshoot cue.
    /// The grip gesture is isolated to its small zone, so click-to-select is safe.
    ///
    /// Known limitation: tuned for COLLAPSED top-level folders (the common case).
    /// Reordering a folder while it's expanded, or within a long *scrolled* root
    /// list, can look off (oversized gap / off-screen rows aren't measured) — the
    /// final placement stays correct (`commitReorder` is identity-based), only the
    /// in-flight visuals degrade.
    @ViewBuilder
    private func rootRow(_ node: FolderNode, index: Int) -> some View {
        if let model = reorderableRoot(for: node) {
            FolderTreeNode(node: node, depth: 0,
                           topLevelCount: topLevelCount(for: node),
                           reorder: sortMode == .manual ? ReorderContext(
                onChanged: { value in
                    if draggingRoot?.id != model.id {
                        // Need a layout snapshot to compute slots; if none has
                        // arrived yet, don't enter drag (else everything would
                        // resolve to "append to end").
                        guard !rootFrames.isEmpty else { return }
                        draggingRoot = model
                        dragStartFrames = rootFrames   // freeze static layout
                    }
                    dragOffset = value.translation.height
                    let newTarget = reorderSlot(forY: value.location.y)
                    if newTarget != dropTarget {
                        // Animate only the parting (slot change), not the live
                        // finger-follow offset.
                        withAnimation(.easeInOut(duration: 0.16)) { dropTarget = newTarget }
                    }
                },
                onEnded: { _ in commitReorder(moving: model) }
            ) : nil)
                // Report this row's static frame (consumed via the drag-start
                // snapshot) for the slot + parting math.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: RootFramePreference.self,
                            value: [model.id: geo.frame(in: .named(Self.reorderSpace))])
                    }
                )
                // The dragged row is hidden in place (its slot stays so the others
                // can part around it); an opaque copy is drawn on TOP via a
                // ScrollView overlay — LazyVStack ignores zIndex, so a top overlay
                // is the reliable way to keep it above the rows it passes.
                .offset(y: isDraggingRoot(model) ? 0 : rowShift(forIndex: index))
                .opacity(isDraggingRoot(model) ? 0 : 1)
        } else {
            FolderTreeNode(node: node, depth: 0, topLevelCount: topLevelCount(for: node))
        }
    }

    private func isDraggingRoot(_ model: Root) -> Bool { draggingRoot?.id == model.id }

    /// Insertion slot (0...others.count) for a drag at vertical position `y`,
    /// measured against the static `otherReorderRoots` midpoints (the dragged
    /// row is excluded — its frame moves with the drag and would corrupt this).
    private func reorderSlot(forY y: CGFloat) -> Int {
        let others = otherReorderRoots
        for (i, r) in others.enumerated() {
            guard let f = dragStartFrames[r.id] else { continue }
            if y < f.midY { return i }
        }
        return others.count
    }

    /// Commit the dragged folder to the computed slot (an index into
    /// `otherReorderRoots`) and reset the drag state.
    private func commitReorder(moving: Root) {
        let target = dropTarget
        let others = reorderableNodes
            .compactMap { reorderableRoot(for: $0) }
            .filter { $0.id != moving.id }
        // Commit WITHOUT animation. After parting, the rows are already in their
        // final visual positions, so reordering the array + clearing the offsets
        // in one non-animated transaction leaves everything in place and the
        // dragged row simply appears in the gap — no snap-back / pass-through.
        // NOTE: this depends on `bookmarks.$roots` delivering SYNCHRONOUSLY (the
        // AppState sink has no `.receive(on:)`), so `rootNodes` rebuilds inside
        // this transaction. If that sink ever gains async delivery, the offsets
        // would clear a frame before the new order applies → a one-frame snap.
        guard let target else { resetDrag(); return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if target >= others.count {
                appState.bookmarks.reorder(moving, relativeTo: others.last, placeAfter: true)
            } else {
                appState.bookmarks.reorder(moving, relativeTo: others[target], placeAfter: false)
            }
            resetDrag()
        }
    }

    /// Clear all transient reorder-drag state.
    private func resetDrag() {
        draggingRoot = nil
        dropTarget = nil
        dragOffset = 0
        dragStartFrames = [:]
    }

    /// Trailing space below the last folder so the "append to end" gap has room
    /// for the insertion line (drawn by the shared overlay at the last row's
    /// bottom edge).
    private var endDropZone: some View {
        Color.clear.frame(height: 24)
    }
}

// MARK: - Root row frame collection

/// Collects each reorderable root row's frame (in `SidebarView.reorderSpace`) so
/// the reorder drag gesture can map a vertical position to an insertion slot.
private struct RootFramePreference: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Reorder-in-progress flag

/// True while a folder reorder drag is in progress. Rows read it to suppress
/// their hover fill (and grip) so passing the dragged row over them doesn't light
/// each one up. Propagated via the environment so every nested row sees it.
private struct SidebarReorderingKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var sidebarReordering: Bool {
        get { self[SidebarReorderingKey.self] }
        set { self[SidebarReorderingKey.self] = newValue }
    }
}

// MARK: - Folder tree node

/// One folder row plus its (lazily loaded) subfolders. Tapping the label
/// selects the folder; tapping the chevron expands/collapses it.
private struct FolderTreeNode: View {
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
        return appState.selectedFolder?.id == node.id
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
            .contentShape(Rectangle())
            // Plain tap-to-select on the row label. Reliable because the only drag
            // source (the grip) is an isolated AppKit view, not a SwiftUI .onDrag
            // on this hosting view (see SidebarView.rootRow).
            .onTapGesture { appState.select(folder: node) }
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
            let selected = appState.effectiveSelectionURLs(fallback: "")
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

// MARK: - Starred row

/// A starred-folder shortcut, styled to match the folder tree rows.
private struct StarRow: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.sidebarReordering) private var isReordering
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
                .fill(Color.primary.opacity(isHovered && !isReordering ? SidebarView.rowHoverFillOpacity : 0))
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

// MARK: - Reorder gesture context

/// Reorder drag handlers for a reorderable top-level folder's grip. The grip's
/// DragGesture forwards to these; SidebarView updates the lift offset + insertion
/// slot and commits the move (a live gesture — no pasteboard drag image).
private struct ReorderContext {
    let onChanged: (DragGesture.Value) -> Void
    let onEnded: (DragGesture.Value) -> Void
}
