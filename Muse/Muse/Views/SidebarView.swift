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

    // MARK: Collections-in-sidebar (opt-in)

    /// When on, the sidebar shows a second COLLECTIONS section beneath FOLDERS.
    /// Off = the sidebar is exactly the original folders-only experience.
    @AppStorage(AppSettings.showCollectionsInSidebarKey) private var showCollectionsInSidebar = true
    @AppStorage(AppSettings.showICloudFolderInSidebarKey) private var showICloudFolder = true
    @ObservedObject private var collectionsEngine = CollectionsEngine.shared
    // Plain @State (seeded from + persisted to UserDefaults) rather than
    // @AppStorage so the collapse can animate via `withAnimation` — a
    // withAnimation transaction doesn't carry into an @AppStorage publish, which
    // made the section open/close instant. Keys persist the choice across launches.
    private static let foldersCollapsedKey = "sidebarFoldersCollapsed"
    private static let collectionsCollapsedKey = "sidebarCollectionsCollapsed"
    @State private var foldersCollapsed =
        UserDefaults.standard.bool(forKey: SidebarView.foldersCollapsedKey)
    @State private var collectionsCollapsed =
        UserDefaults.standard.bool(forKey: SidebarView.collectionsCollapsedKey)

    // Collection reorder drag — a flat-list mirror of the folder reorder above.
    @State private var draggingCollectionID: String?
    @State private var collectionDropTarget: Int?
    @State private var collectionDragOffset: CGFloat = 0
    @State private var collectionFrames: [String: CGRect] = [:]
    @State private var collectionDragStartFrames: [String: CGRect] = [:]

    /// Height of a single collapsed folder row.
    fileprivate static let rowHeight: CGFloat = 28
    /// Named coordinate space shared by the reorder drag gesture and the row
    /// frame measurements, so the two are always compared in the same space.
    /// Internal (not fileprivate): the row/support types in Views/Sidebar/ read it.
    static let reorderSpace = "sidebarReorder"

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
            } else if showCollectionsInSidebar {
                twoSectionScroll
            } else {
                sortHeader
                foldersScroll
            }

            bottomBar
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

    // MARK: - Folder list (shared by both layouts)

    /// The folder tree content (iCloud home, stars, reorderable roots). Extracted
    /// so both the folders-only ScrollView and the two-section ScrollView reuse it.
    @ViewBuilder private var folderList: some View {
        // A non-lazy VStack iterated DIRECTLY by node id (mirrors collectionsList).
        // A LazyVStack here could de-materialize the top-level folder rows when
        // scrolled out of the shared two-section ScrollView and fail to bring them
        // back, leaving an empty FOLDERS section while COLLECTIONS (already a plain
        // VStack) stayed intact. The top-level root list is short (children live in
        // FolderTreeNode), so there's no virtualization cost, and always-realized
        // rows make the drag-reorder frame preferences reliable.
        VStack(alignment: .leading, spacing: 1) {
            // The iCloud "Muse" folder is the fixed home — always on top, not
            // reorderable. It sits in the normal row rhythm (VStack spacing) with
            // the local folders below it, no extra separating gap.
            // The user may hide the iCloud row from the sidebar ONLY while it's
            // empty (Settings → Sidebar); a folder with files always shows. The
            // gate reads the live recursive count, not just the persisted flag,
            // so a folder that gains files reappears on its own. (iCloudNode
            // being non-nil already means iCloud is configured.)
            if let icloud = iCloudNode,
               ICloudSidebarVisibility.rowVisible(
                   ICloudSidebarVisibility.presence(
                       configured: true,
                       recursiveFileCount: appState.folderStats.stat(for: icloud.url)?.recursiveFileCount),
                   showSetting: showICloudFolder) {
                FolderTreeNode(node: icloud, depth: 0,
                               topLevelCount: topLevelCount(for: icloud))
            }

            if !appState.stars.starred.isEmpty {
                ForEach(appState.stars.starred) { star in
                    StarRow(star: star)
                }
            }

            ForEach(displayedReorderableNodes, id: \.id) { node in
                rootRow(node, index: displayedReorderableNodes.firstIndex { $0.id == node.id } ?? 0)
            }
            // Catch-area below the last folder so a drag released in the empty
            // space underneath still lands at the bottom.
            if !reorderableNodes.isEmpty { endDropZone }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// Folders-only scroll (setting OFF) — the original experience.
    private var foldersScroll: some View {
        ScrollView { folderList }
            .scrollContentBackground(.hidden)
            .coordinateSpace(name: Self.reorderSpace)
            .onPreferenceChange(RootFramePreference.self) { rootFrames = $0 }
            .environment(\.sidebarReordering, draggingRoot != nil)
            // Safety net: if the dragged root disappears mid-drag the gesture's
            // .onEnded may never fire, stranding the sidebar in drag state.
            .onChange(of: reorderableNodes.map(\.id)) { _, _ in
                if draggingRoot != nil, draggedIndex == nil { resetDrag() }
            }
            .overlay(alignment: .top) { folderInsertionOverlay }
            .overlay(alignment: .top) { folderDraggedOverlay }
    }

    /// Backup insertion line for the folder reorder (helps on overshoot).
    @ViewBuilder private var folderInsertionOverlay: some View {
        if draggingRoot != nil, let y = insertionLineY() {
            insertionLine.offset(y: y - 1).allowsHitTesting(false)
        }
    }

    /// Opaque floating copy of the dragged folder row, above everything.
    @ViewBuilder private var folderDraggedOverlay: some View {
        if let dragging = draggingRoot, let f = dragStartFrames[dragging.id] {
            draggedRowOverlay(dragging)
                .offset(y: f.minY + dragOffset)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Two-section layout (setting ON)

    /// FOLDERS + COLLECTIONS in one scroll so they scroll together; the bottom
    /// pill row stays pinned (it lives outside this view, in `body`).
    private var twoSectionScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: String(localized: "FOLDERS"), collapsed: $foldersCollapsed)
                if !foldersCollapsed {
                    sortHeader
                    folderList
                }
                // Content-gated: with no folders at all, or only an empty iCloud
                // "Muse" root (no reachable images anywhere), there's nothing to
                // collect, so the whole COLLECTIONS section hides — not just its rows
                // (a header over an empty list read as a bug when everything was
                // removed). Requires BOTH a real root AND reachable content: content
                // alone would show ghost collections at zero roots (the reachable
                // sentinel reads "unknown → true" before roots are pushed). Reappears
                // the moment reachable images exist under a root again.
                if !appState.rootNodes.isEmpty && collectionsEngine.hasReachableContent {
                    // Fixed inter-section spacer (drives the COLLAPSED-state gap
                    // between the two headers — kept at the original 14). The
                    // OPEN-state gap is trimmed separately via folderList's bottom
                    // padding + the shorter endDropZone, which render only when the
                    // FOLDERS section is expanded.
                    Color.clear.frame(height: 14)
                    SectionHeader(title: String(localized: "COLLECTIONS"), collapsed: $collectionsCollapsed)
                    if !collectionsCollapsed {
                        collectionsSortHeader
                        collectionsList
                    }
                }
            }
        }
        // Persist the collapse choices (the flags are plain @State so they can
        // animate via withAnimation; no container `.animation(value:)` modifier,
        // which would otherwise spring-animate the sort/reorder list changes too).
        .onChange(of: foldersCollapsed) { _, v in
            UserDefaults.standard.set(v, forKey: Self.foldersCollapsedKey)
        }
        .onChange(of: collectionsCollapsed) { _, v in
            UserDefaults.standard.set(v, forKey: Self.collectionsCollapsedKey)
        }
        .scrollContentBackground(.hidden)
        .coordinateSpace(name: Self.reorderSpace)
        .onPreferenceChange(RootFramePreference.self) { rootFrames = $0 }
        .onPreferenceChange(CollectionFramePreference.self) { collectionFrames = $0 }
        .environment(\.sidebarReordering, draggingRoot != nil || draggingCollectionID != nil)
        .onChange(of: reorderableNodes.map(\.id)) { _, _ in
            if draggingRoot != nil, draggedIndex == nil { resetDrag() }
        }
        .onChange(of: appState.sidebarCollections.map { $0.collection.id }) { _, _ in
            if draggingCollectionID != nil, draggedCollectionIndex == nil { resetCollectionDrag() }
        }
        .overlay(alignment: .top) { folderInsertionOverlay }
        .overlay(alignment: .top) { folderDraggedOverlay }
        .overlay(alignment: .top) { collectionInsertionOverlay }
        .overlay(alignment: .top) { collectionDraggedOverlay }
    }

    // MARK: - Collections sort header

    private var collectionsSortHeader: some View {
        HStack {
            Menu {
                ForEach(SidebarCollectionSortMode.allCases) { mode in
                    Button { setCollectionSortMode(mode) } label: {
                        if appState.sidebarCollectionSortMode == mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Sort: \(appState.sidebarCollectionSortMode.label)")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Sort collections")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private func setCollectionSortMode(_ mode: SidebarCollectionSortMode) {
        // No global withAnimation: a global transaction animates the whole
        // surrounding VStack (the folder section + conditional content), which
        // read as a fly-in. The reorder is animated locally, scoped to the list
        // (see collectionsList's `.animation(value:)`), so rows just move.
        appState.sidebarCollectionSortMode = mode
    }

    // MARK: - Collections list

    @ViewBuilder private var collectionsList: some View {
        // A non-lazy VStack (the collection list is short) iterated DIRECTLY by
        // collection id — `LazyVStack` + `Array(enumerated())` made SwiftUI treat
        // a sort reorder as insert/remove and fly rows in from the edge. A stable
        // identity over a realized stack animates the reorder as in-place moves.
        VStack(alignment: .leading, spacing: 1) {
            ForEach(appState.sidebarCollections, id: \.collection.id) { loaded in
                collectionRow(loaded)
            }
            if !appState.sidebarCollections.isEmpty { endDropZone }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 12)
        // Animate the reorder ONLY when the sort mode changes, scoped to this
        // list — rows move in place instead of the surrounding layout flying in.
        .animation(.easeInOut(duration: 0.2), value: appState.sidebarCollectionSortMode)
    }

    /// One collection row, wired for Manual drag-reorder (a flat-list mirror of
    /// `rootRow`): the dragged row is hidden in place while an opaque copy follows
    /// the cursor; others part around the gap.
    @ViewBuilder
    private func collectionRow(_ loaded: CollectionStore.Loaded) -> some View {
        let id = loaded.collection.id
        let index = appState.sidebarCollections.firstIndex { $0.collection.id == id } ?? 0
        CollectionSidebarRow(
            loaded: loaded,
            index: index,
            count: appState.sidebarCollections.count,
            manual: appState.sidebarCollectionSortMode == .manual,
            reorder: appState.sidebarCollectionSortMode == .manual ? ReorderContext(
                onChanged: { value in
                    if draggingCollectionID != id {
                        guard !collectionFrames.isEmpty else { return }
                        draggingCollectionID = id
                        collectionDragStartFrames = collectionFrames
                    }
                    collectionDragOffset = value.translation.height
                    let newTarget = collectionReorderSlot(forY: value.location.y)
                    if newTarget != collectionDropTarget {
                        withAnimation(.easeInOut(duration: 0.16)) { collectionDropTarget = newTarget }
                    }
                },
                onEnded: { _ in commitCollectionReorder(movingID: id) }
            ) : nil
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: CollectionFramePreference.self,
                    value: [id: geo.frame(in: .named(Self.reorderSpace))])
            }
        )
        .offset(y: draggingCollectionID == id ? 0 : collectionRowShift(forIndex: index))
        .opacity(draggingCollectionID == id ? 0 : 1)
    }

    // MARK: - Collection reorder math (mirrors the folder reorder)

    /// Ordered collection ids EXCLUDING the dragged one.
    private var otherCollectionIDs: [String] {
        appState.sidebarCollections.map { $0.collection.id }
            .filter { $0 != draggingCollectionID }
    }

    private var draggedCollectionIndex: Int? {
        guard let id = draggingCollectionID else { return nil }
        return appState.sidebarCollections.firstIndex { $0.collection.id == id }
    }

    private func collectionRowShift(forIndex i: Int) -> CGFloat {
        let pitch = (draggingCollectionID.flatMap { collectionDragStartFrames[$0]?.height }
                     ?? Self.rowHeight) + 1
        return ReorderMath.rowShift(forIndex: i, draggedIndex: draggedCollectionIndex,
                                    dropTarget: collectionDropTarget, pitch: pitch)
    }

    private func collectionReorderSlot(forY y: CGFloat) -> Int {
        ReorderMath.slot(forY: y,
                         orderedStartFrames: otherCollectionIDs.map { collectionDragStartFrames[$0] })
    }

    private func collectionInsertionLineY() -> CGFloat? {
        ReorderMath.insertionLineY(dropTarget: collectionDropTarget,
                                   orderedLiveFrames: otherCollectionIDs.map { collectionFrames[$0] })
    }

    private func commitCollectionReorder(movingID: String) {
        let target = collectionDropTarget
        let others = otherCollectionIDs
        guard let target else { resetCollectionDrag(); return }
        // Build the final id order, then persist + reset in a non-animated
        // transaction (rows are already in their final visual positions).
        var newOrder = others
        let insertAt = min(target, newOrder.count)
        newOrder.insert(movingID, at: insertAt)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            appState.reorderSidebarCollections(newOrder)
            resetCollectionDrag()
        }
    }

    private func resetCollectionDrag() {
        draggingCollectionID = nil
        collectionDropTarget = nil
        collectionDragOffset = 0
        collectionDragStartFrames = [:]
    }

    @ViewBuilder private var collectionInsertionOverlay: some View {
        if draggingCollectionID != nil, let y = collectionInsertionLineY() {
            insertionLine.offset(y: y - 1).allowsHitTesting(false)
        }
    }

    @ViewBuilder private var collectionDraggedOverlay: some View {
        if let id = draggingCollectionID,
           let loaded = appState.sidebarCollections.first(where: { $0.collection.id == id }),
           let f = collectionDragStartFrames[id] {
            draggedCollectionOverlay(loaded)
                .offset(y: f.minY + collectionDragOffset)
                .allowsHitTesting(false)
        }
    }

    /// Opaque copy of the dragged collection row (mirrors `draggedRowOverlay`).
    private func draggedCollectionOverlay(_ loaded: CollectionStore.Loaded) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 20)
            Text(loaded.collection.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 6)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 22)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(cardColor))
        .scaleEffect(1.02)
        .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
        .padding(.horizontal, 8)
    }

    // MARK: - Bottom bar

    /// One "Add Folder" pill when off (or on first run, before any folder
    /// exists — a collection with nothing behind it is a dead end, so Add
    /// Collection isn't offered yet); two compact pills (Add Folder + Add
    /// Collection) once the Collections section is shown AND a folder exists.
    @ViewBuilder private var bottomBar: some View {
        // Offer "Add Collection" only when a real folder holds reachable images to
        // collect; first run / empty library gets just "Add Folder" (the real next
        // step — a collection with nothing behind it is a dead end), matching the
        // content-gated COLLECTIONS section above (both a root AND content).
        if showCollectionsInSidebar && !appState.rootNodes.isEmpty
            && collectionsEngine.hasReachableContent {
            HStack(spacing: 10) {
                AddPillButton(systemImage: "folder", label: String(localized: "Add Folder")) {
                    appState.pickAndAddRoot()
                }
                AddPillButton(systemImage: "square.stack.3d.up", label: String(localized: "Add Collection")) {
                    appState.requestNewCollection()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        } else {
            AddFolderPillButton { appState.pickAndAddRoot() }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
            // Disambiguate from the COLLECTIONS sort pop-up (same visible "Sort:…"
            // shape) now that both can sit in the sidebar at once.
            .accessibilityLabel("Sort folders")
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
        ReorderMath.insertionLineY(dropTarget: dropTarget,
                                   orderedLiveFrames: otherReorderRoots.map { rootFrames[$0.id] })
    }

    /// An opaque copy of the dragged folder row, drawn as a ScrollView overlay so
    /// it stays above every row it passes (a single floating copy is simpler and
    /// more reliable than per-row zIndex juggling; mirrors collectionDraggedOverlay).
    /// Mirrors the real row's metrics so it lands seamlessly.
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
        let pitch = (draggingRoot.flatMap { dragStartFrames[$0.id]?.height }
                     ?? Self.rowHeight) + 1   // + VStack spacing
        return ReorderMath.rowShift(forIndex: i, draggedIndex: draggedIndex,
                                    dropTarget: dropTarget, pitch: pitch)
    }

    /// One draggable top-level folder. Reorder is a LIVE gesture, not pasteboard
    /// drag-and-drop: the trailing grip drives a DragGesture; the dragged row is
    /// hidden in place (so its slot stays and the others can part around it) while
    /// an opaque copy (`draggedRowOverlay`) follows the cursor on top — a single
    /// floating overlay keeps it above the rows it passes without per-row zIndex
    /// juggling. A faint insertion line marks the gap as an overshoot cue.
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
                // ScrollView overlay — a single floating copy keeps it above the
                // rows it passes without per-row zIndex juggling.
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
        ReorderMath.slot(forY: y,
                         orderedStartFrames: otherReorderRoots.map { dragStartFrames[$0.id] })
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
        Color.clear.frame(height: 12)
    }
}
