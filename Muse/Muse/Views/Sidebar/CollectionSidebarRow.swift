//
//  CollectionSidebarRow.swift
//  Muse
//
//  One collection row in the opt-in sidebar Collections section.
//  Extracted verbatim from SidebarView.swift in the 2026-06-20 code-health
//  refactor (file moves only; `private` types became internal so they can live
//  in their own files). Behavior unchanged.
//

import SwiftUI
import AppKit

// MARK: - Collection sidebar row

/// One collection in the sidebar's COLLECTIONS section: stack icon, name, and
/// alive-image count. Click activates it in the grid (like the Collections
/// page); right-click renames/deletes/moves; in Manual sort a trailing grip
/// (swapping with the count on hover) drives the live drag-reorder.
struct CollectionSidebarRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject private var googleAuth: GoogleOAuth
    @Environment(\.sidebarReordering) private var isReordering
    let loaded: CollectionStore.Loaded
    let index: Int
    let count: Int
    let manual: Bool
    var reorder: ReorderContext? = nil

    // Mirror the grid's current density (the bottom-right column slider) —
    // same global setting `ShareCollectionButton` reads for the open collection.
    @AppStorage("gridColumnCount") private var gridColumns = 4
    @State private var isHovered = false
    @State private var confirmDelete = false
    @State private var preparingExport = false
    @State private var showingDriveShare = false
    @State private var showingCustomize = false
    @State private var showingRules = false
    @State private var driveShareURLs: [URL] = []
    @State private var exportFailed = false

    private var id: String { loaded.collection.id }
    private var isSmart: Bool { loaded.collection.smart_rules != nil }

    /// A user-chosen icon (v10) always wins; otherwise a smart collection shows
    /// the rule/funnel glyph and everything else shows the classic stack.
    private var rowIcon: String {
        if let icon = loaded.collection.icon { return CollectionAppearance.resolvedIcon(icon) }
        return isSmart ? CollectionAppearance.smartDefaultIcon : CollectionAppearance.defaultIcon
    }

    private var isSelected: Bool {
        // Highlight whenever this collection is the active one — no matter how you
        // got into it (sidebar click OR a card on the Collections page). A folder
        // never shows selected while a collection is active, so there's no clash.
        appState.activeCollectionID == id
    }

    var body: some View {
        HStack(spacing: 8) {
            // Invisible chevron placeholder (matches FolderTreeNode leaves) so a
            // collection's icon + name line up exactly with the folder rows above.
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .opacity(0)
                .frame(width: 10)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                // Custom appearance (feat/next-128): stored symbol + color
                // token, both nil = the classic stack icon. A custom color
                // paints the ICON ONLY — name + selection stay standard —
                // and holds even while selected, so the row keeps its
                // identity color.
                Image(systemName: rowIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconStyle)
                    .frame(width: 18)

                Text(loaded.collection.name)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor)
                                                : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6)

                // Trailing slot: the count, swapping in place for the drag grip on
                // hover (Manual only). During a drag the floating overlay shows the
                // grip, so in-list rows fall back to the count.
                let showGrip = reorder != nil && isHovered && !isReordering
                ZStack(alignment: .trailing) {
                    Text("\(loaded.aliveCount)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .opacity(showGrip ? 0 : 1)
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
                            .onTapGesture { appState.setActiveCollection(id) }
                            .help("Drag to reorder")
                            .accessibilityHidden(true)
                    }
                }
            }
            // Plain tap-to-open on the row content (mirrors FolderTreeNode, where
            // the tap lives on the inner HStack and hover/menu on the outer).
            .contentShape(Rectangle())
            .onTapGesture { appState.setActiveCollection(id) }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(rowFill)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .contextMenu {
            Button("Save to…") { Task { await exportSave() } }
                .disabled(loaded.aliveCount == 0 || preparingExport)
            Button("Share Drive Link") { Task { await exportDriveShare() } }
                .disabled(loaded.aliveCount == 0 || preparingExport)
            Divider()
            Button("Rename…") {
                appState.collectionRenameAlertRequest = CollectionRenameAlertRequest(
                    id: id, currentName: loaded.collection.name)
            }
            Button("Change Symbol & Color…") { showingCustomize = true }
            if isSmart {
                Button("Edit Rules…") { showingRules = true }
            } else {
                Button("Make Smart…") { showingRules = true }
            }
            Button("Delete…") { confirmDelete = true }
            if manual {
                Divider()
                Button("Move Up") { appState.moveSidebarCollection(id: id, by: -1) }
                    .disabled(index <= 0)
                Button("Move Down") { appState.moveSidebarCollection(id: id, by: 1) }
                    .disabled(index >= count - 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(loaded.collection.name), \(loaded.aliveCount) "
                            + (loaded.aliveCount == 1 ? String(localized: "item") : String(localized: "items")))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { appState.setActiveCollection(id) }
        .accessibilityActions {
            if loaded.aliveCount > 0 {
                Button("Save to…") { Task { await exportSave() } }
                Button("Share Drive Link") { Task { await exportDriveShare() } }
            }
            Button("Rename Collection") {
                appState.collectionRenameAlertRequest = CollectionRenameAlertRequest(
                    id: id, currentName: loaded.collection.name)
            }
            Button("Change Symbol & Color") { showingCustomize = true }
            Button(isSmart ? String(localized: "Edit Rules") : String(localized: "Make Smart")) { showingRules = true }
            Button("Delete Collection") { confirmDelete = true }
            // Move actions only when Manual sort permits reordering, and only in
            // the non-boundary direction(s) — mirrors the context menu's disabled
            // gating so VoiceOver never offers a dead "Move Up/Down" (e.g. on the
            // top row, or in a sorted mode where reordering does nothing).
            if manual {
                if index > 0 {
                    Button("Move Up") { appState.moveSidebarCollection(id: id, by: -1) }
                }
                if index < count - 1 {
                    Button("Move Down") { appState.moveSidebarCollection(id: id, by: 1) }
                }
            }
        }
        .alert("Delete “\(loaded.collection.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                let cid = id
                Task { @MainActor in
                    guard let q = Database.shared.dbQueue else { return }
                    if appState.activeCollectionID == cid { appState.setActiveCollection(nil) }
                    try? await CollectionStore.setHidden(queue: q, id: cid, hidden: true)
                    await CollectionsEngine.shared.reload()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The collection is removed everywhere. Your images stay on disk.")
        }
        .sheet(isPresented: $showingCustomize) {
            CustomizeCollectionSheet(loaded: loaded) { showingCustomize = false }
        }
        .sheet(isPresented: $showingRules) {
            SmartCollectionRulesView(
                collectionID: id,
                initialName: loaded.collection.name,
                initialSet: loaded.collection.smart_rules.flatMap(SmartRuleSet.decode)
                    ?? SmartRuleSet(match: .all, rules: []),
                confirmConversion: !isSmart && loaded.aliveCount > 0) {
                showingRules = false
            }
        }
        .sheet(isPresented: $showingDriveShare) {
            DriveShareSheet(auth: googleAuth, title: loaded.collection.name, urls: driveShareURLs) {
                showingDriveShare = false
            }
        }
        .alert("Couldn’t Export the PDF", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The PDF couldn’t be prepared — some images may be unreadable — or the location couldn’t be written. Check the images and that the location is writable with enough free space.")
        }
    }

    /// Icon color: the stored custom token wins (even while selected — it's
    /// the collection's identity color); no token = the classic
    /// primary / accent-when-selected.
    private var iconStyle: AnyShapeStyle {
        if let custom = CollectionAppearance.color(for: loaded.collection.color) {
            return AnyShapeStyle(custom)
        }
        return isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary)
    }

    private var rowFill: Color {
        if isSelected { return Color.accentColor.opacity(0.14) }
        let showHover = isHovered && !isReordering
        return Color.primary.opacity(showHover ? SidebarView.rowHoverFillOpacity : 0)
    }

    // MARK: - Export (Save to… / Share Drive Link)

    /// Member URLs for THIS row's collection (not necessarily the active
    /// one) — same reachability rule as the grid (`AppState.setActiveCollection`):
    /// only members under a currently mounted root are exportable.
    private func exportURLs() async -> [URL] {
        await appState.exportableURLs(forCollection: id)
    }

    private func exportSave() async {
        let urls = await exportURLs()
        guard !urls.isEmpty else { exportFailed = true; return }
        preparingExport = true
        defer { preparingExport = false }
        let outcome = await CollectionPDFSave.run(
            title: loaded.collection.name, urls: urls, appState: appState, gridColumns: gridColumns)
        if outcome == .failed { exportFailed = true }
    }

    private func exportDriveShare() async {
        let urls = await exportURLs()
        guard !urls.isEmpty else { exportFailed = true; return }
        driveShareURLs = urls
        showingDriveShare = true
    }
}

