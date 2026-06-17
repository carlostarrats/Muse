//
//  TagChipsRow.swift
//  Muse
//
//  Cosmos-style tag chip row above the main grid: the library's most-used
//  tag labels, horizontally scrollable. Tapping a chip filters the grid to
//  files carrying that tag (the chips stay put — same pattern as the
//  collection filter); "All" or re-tapping clears it.
//
//  Hover reveals the tag's image count with the viewer pills' no-reflow
//  behavior: the hovered chip grows by a fixed amount and the FOLLOWING
//  chips condense to absorb it (PillRowModel math), so the row's total
//  width — and every chip before the hovered one — never moves.
//

import SwiftUI
import AppKit
import GRDB

struct TagChipsRow: View {
    @EnvironmentObject var appState: AppState
    @State private var tags: [(label: String, count: Int)] = []
    @State private var hovered: Int? = nil
    @State private var renameText = ""

    var body: some View {
        // ZStack, not Group: an empty Group has no children, so .task
        // would never fire and the labels would never load.
        ZStack {
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    ChipFlow(gap: 8, hovered: hovered, grow: growForHovered, noGrow: [0]) {
                        TagChip(index: 0, label: "All", count: nil,
                                isSelected: appState.activeTagLabel == nil,
                                isHovered: hovered == 0,
                                onHover: hover) {
                            appState.setActiveTag(nil)
                        }
                        ForEach(Array(tags.enumerated()), id: \.element.label) { i, tag in
                            TagChip(index: i + 1, label: tag.label, count: tag.count,
                                    isSelected: appState.activeTagLabel == tag.label,
                                    isHovered: hovered == i + 1,
                                    onHover: hover) {
                                appState.setActiveTag(
                                    appState.activeTagLabel == tag.label ? nil : tag.label)
                            }
                            .contextMenu {
                                Button("Rename Tag…") {
                                    appState.tagRenameRequest = tag.label
                                }
                                Button("Delete Tag…", role: .destructive) {
                                    appState.tagDeleteRequest = tag.label
                                }
                            }
                        }
                    }
                    .animation(.easeOut(duration: 0.18), value: hovered)
                    .padding(.horizontal, 14)
                }
                .padding(.top, 10)
                // Constant gap below the chips so the grid sits at the same
                // height whether a tag is selected or "All" — no vertical
                // jump on selection. (The old inline collections row that the
                // filtered/unfiltered split accommodated is gone.)
                .padding(.bottom, 24)
            } else {
                // No tags → no chips. Reserve ONLY the chip row's top clearance
                // (the 10pt gap below the toolbar), NOT the chip + bottom gap, so
                // the first image row sits right where the chips would — raised,
                // not the full dead space — while still clearing the floating
                // toolbar so the top row never hides behind the search bar.
                Color.clear.frame(height: 10)
            }
        }
        .task(id: reloadKey) { await loadLabels() }
        .onChange(of: appState.tagRenameRequest) { _, label in
            if let label { renameText = label }
        }
        .alert("Rename Tag", isPresented: Binding(
            get: { appState.tagRenameRequest != nil },
            set: { if !$0 { appState.tagRenameRequest = nil } }
        )) {
            TextField("Tag name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { appState.tagRenameRequest = nil }
        } message: {
            Text("Renames “\(appState.tagRenameRequest ?? "")” on every image in the library.")
        }
        .alert("Delete “\(appState.tagDeleteRequest ?? "")”?", isPresented: Binding(
            get: { appState.tagDeleteRequest != nil },
            set: { if !$0 { appState.tagDeleteRequest = nil } }
        )) {
            Button("Delete", role: .destructive) { commitDelete() }
            Button("Cancel", role: .cancel) { appState.tagDeleteRequest = nil }
        } message: {
            Text("Removes “\(appState.tagDeleteRequest ?? "")” from the images in this view. Other folders keep their tags. Your images stay on disk.")
        }
        .alert("Delete all tags in this folder?", isPresented: $appState.deleteAllTagsRequest) {
            Button("Delete All", role: .destructive) { commitDeleteAllTags() }
            Button("Cancel", role: .cancel) { appState.deleteAllTagsRequest = false }
        } message: {
            Text("This removes every tag on the images in this folder — both automatic tags and ones you've added yourself. Tags you added by hand can't be recovered. Your images stay on disk.")
        }
        .alert("Regenerate tags for this folder?", isPresented: $appState.regenerateTagsRequest) {
            Button("Regenerate") { commitRegenerateTags() }
            Button("Cancel", role: .cancel) { appState.regenerateTagsRequest = false }
        } message: {
            Text("Looks for images in this folder that have no tags and generates tags for them in the background. Images that already have tags are left alone. Only automatic tags are created — tags you added by hand aren't restored.")
        }
    }

    private func commitRename() {
        guard let old = appState.tagRenameRequest else { return }
        let new = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.tagRenameRequest = nil
        guard !new.isEmpty, new != old else { return }
        Task { @MainActor in
            await TagStore.shared.renameLabel(from: old, to: new)
            if appState.activeTagLabel == old { appState.setActiveTag(new) }
            appState.tagsVersion += 1
        }
    }

    private func commitDelete() {
        guard let label = appState.tagDeleteRequest else { return }
        appState.tagDeleteRequest = nil
        // Scope the delete to the current view's files (this folder, or this
        // collection's members) — NOT the whole library. Tags belong to a file
        // in its folder; deleting here must never touch other folders.
        let urls = appState.tagSourceFiles.map { $0.url }
        appState.removeTag(label, fromURLs: urls)
    }

    private func commitDeleteAllTags() {
        appState.deleteAllTagsRequest = false
        let urls = appState.currentFiles.map { $0.url }
        Task { @MainActor in
            await TagStore.shared.deleteAllTags(forURLs: urls)
            appState.setActiveTag(nil)
            appState.tagsVersion += 1
        }
    }

    private func commitRegenerateTags() {
        appState.regenerateTagsRequest = false
        let urls = appState.currentFiles.map { $0.url }
        Task { @MainActor in
            await AnalyzePipeline.shared.regenerateTagless(in: urls)
            appState.tagsVersion += 1
        }
    }

    private func hover(_ index: Int, _ inside: Bool) {
        if inside { hovered = index }
        else if hovered == index { hovered = nil }
    }

    /// How far the hovered chip should grow: just enough for its count plus a
    /// fixed gap, so the space between the label and the number is the same for
    /// "1" and "1234" (a fixed grow left a big gap after short counts). Index 0
    /// is "All" (no count) and is in ChipFlow's noGrow set, so its grow is moot.
    private var growForHovered: CGFloat {
        guard let h = hovered, h >= 1, h - 1 < tags.count else { return 0 }
        return Self.countWidth(tags[h - 1].count) + 5
    }

    /// Rendered width of the count in the exact font the overlay draws it in.
    private static func countWidth(_ count: Int) -> CGFloat {
        let s = "\(count)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ]
        return ceil(s.size(withAttributes: attrs).width)
    }

    /// Reload when tags mutate, the sidebar selection changes, the folder's
    /// contents land/refresh, or the active collection changes (the chips
    /// re-scope to the collection's members inside one).
    private var reloadKey: String {
        "\(appState.tagsVersion)|\(appState.activeCollectionID ?? appState.selectedFolder?.url.path ?? "")|\(appState.tagSourceFiles.count)"
    }

    /// Tag labels (with counts) for EXACTLY the files the grid can show — the
    /// collection's members inside a collection, else the current folder.
    /// Deriving from in-memory files (not a DB folder query) means a chip can
    /// never filter down to an empty grid: a tag with no visible images
    /// simply has no chip.
    private func loadLabels() async {
        guard let q = Database.shared.dbQueue else { return }
        let paths = appState.tagSourceFiles.map { $0.url.standardizedFileURL.path }
        guard !paths.isEmpty else {
            tags = []
            return
        }

        // Fast path — a single, non-recursive folder (not inside a collection,
        // not showing subfolders) has ONE constant parent_dir, so the per-label
        // counts come straight from a SQL GROUP BY instead of fetching every tag
        // row for every file and counting them in Swift. This is the path a normal
        // folder switch hits, and where the grid waited longest before it could
        // reveal — so cutting it shortens the brief "empty" gap before the folder
        // appears (most noticeable in a large library).
        if appState.activeCollectionID == nil, !appState.showSubfolders {
            let dir = TagScope.parentDir(ofPath: paths[0])
            revealTags(from: await folderLabelCounts(paths: paths, parentDir: dir, queue: q))
            return
        }

        var counts: [String: Int] = [:]
        for start in stride(from: 0, to: paths.count, by: 500) {
            let chunk = Array(paths[start..<min(start + 500, paths.count)])
            let rows: [(String, Int)] = (try? await q.read { db -> [(String, Int)] in
                let marks = databaseQuestionMarks(count: chunk.count)
                // The (file_id, parent_dir) scopes actually present in THIS view —
                // tags are per-folder, so a duplicate's tag in another folder must
                // not surface here even though it shares the file_id.
                let pathRows = try Row.fetchAll(db, sql: """
                    SELECT file_id, absolute_path FROM paths
                    WHERE is_alive = 1 AND file_id IS NOT NULL AND absolute_path IN (\(marks))
                """, arguments: StatementArguments(chunk))
                var scopeKeys = Set<String>()
                var fileIDs = Set<String>()
                for r in pathRows {
                    guard let fid: String = r["file_id"],
                          let p: String = r["absolute_path"] else { continue }
                    fileIDs.insert(fid)
                    scopeKeys.insert(fid + "\u{0}" + TagScope.parentDir(ofPath: p))
                }
                guard !fileIDs.isEmpty else { return [] }
                let fmarks = databaseQuestionMarks(count: fileIDs.count)
                let tagRows = try Row.fetchAll(db, sql: """
                    SELECT label, file_id, parent_dir FROM tags WHERE file_id IN (\(fmarks))
                """, arguments: StatementArguments(Array(fileIDs)))
                var perLabel: [String: Set<String>] = [:]
                for tr in tagRows {
                    guard let label: String = tr["label"], let fid: String = tr["file_id"],
                          let dir: String = tr["parent_dir"] else { continue }
                    let key = fid + "\u{0}" + dir
                    if scopeKeys.contains(key) { perLabel[label, default: []].insert(key) }
                }
                return perLabel.map { ($0.key, $0.value.count) }
            }) ?? []
            for (label, count) in rows { counts[label, default: 0] += count }
        }
        // Show EVERY tag in scope (the row scrolls horizontally) — capping the
        // list hid tags with no other way to reach them. Most-used first, with
        // an alphabetical tiebreak so equal-count tags keep a stable order
        // (no shuffling between reloads).
        revealTags(from: counts)
    }

    /// Order the counted labels (most-used first, alphabetical tiebreak) and
    /// reveal the row + the grid's images together, already sized — so a tagged
    /// folder shows its chips FIRST and the images never render up top and then
    /// get shoved down. `tagRowReady` ungates the grid (see GridView); the row's
    /// height and the grid reveal land in one animated transaction.
    private func revealTags(from counts: [String: Int]) {
        let ordered = counts
            .sorted {
                $0.value != $1.value
                    ? $0.value > $1.value
                    : $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
            .map { (label: $0.key, count: $0.value) }
        withAnimation(.easeInOut(duration: AppState.navTransition)) {
            tags = ordered
            appState.tagRowReady = true
        }
    }

    /// Per-label counts for a single non-recursive folder via SQL GROUP BY — the
    /// fast path. `parentDir` is the folder's tag scope (constant for all its
    /// files), and `paths` restricts the count to the files actually present, so
    /// a chip can never filter the grid down to empty.
    private func folderLabelCounts(paths: [String], parentDir: String,
                                   queue: DatabaseQueue) async -> [String: Int] {
        (try? await queue.read { db -> [String: Int] in
            var out: [String: Int] = [:]
            for start in stride(from: 0, to: paths.count, by: 800) {
                let chunk = Array(paths[start..<min(start + 800, paths.count)])
                let marks = databaseQuestionMarks(count: chunk.count)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT t.label AS label, COUNT(DISTINCT p.file_id) AS c
                    FROM paths p JOIN tags t ON t.file_id = p.file_id
                    WHERE p.is_alive = 1 AND t.parent_dir = ? AND p.absolute_path IN (\(marks))
                    GROUP BY t.label
                    """, arguments: StatementArguments([parentDir] + chunk))
                for r in rows {
                    guard let label: String = r["label"], let c: Int = r["c"] else { continue }
                    out[label, default: 0] += c
                }
            }
            return out
        }) ?? [:]
    }
}

// MARK: - Layout

/// Single-row PillFlow: total width is always the sum of NATURAL widths, so
/// the scroll content never grows on hover. The hovered chip's +`grow` is
/// absorbed by its immediate neighbors — half from each side, spilling
/// outward only if a neighbor bottoms out at the floor — so movement stays
/// local: left neighbor shrinks in place, hovered grows both ways, right
/// neighbor shrinks against its fixed right edge. Everything else is still.
private struct ChipFlow: Layout {
    var gap: CGFloat
    var hovered: Int?
    var grow: CGFloat
    /// Indices that never grow on hover (the "All" chip has no count).
    var noGrow: Set<Int> = []

    private func naturalSize(_ subviews: Subviews) -> CGSize {
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let h = subviews.first?.sizeThatFits(.unspecified).height ?? 30
        return CGSize(width: widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1)),
                      height: h)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Report the ACTUAL laid-out width. Usually this equals the natural row
        // width (the neighbors absorb the hovered chip's growth, so nothing
        // reflows). Only when the neighbors can't free enough room does the row
        // grow by the small remainder — so a hovered chip can ALWAYS reach the
        // width its count needs, with no cap and no overlap.
        let naturals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let h = subviews.first?.sizeThatFits(.unspecified).height ?? 30
        let effectiveGrow = hovered.map { noGrow.contains($0) ? 0 : grow } ?? 0
        let widths = Self.widths(naturals: naturals, hovered: hovered,
                                 grow: effectiveGrow, floor: 30)
        return CGSize(width: widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1)),
                      height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let naturals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let h = subviews.first?.sizeThatFits(.unspecified).height ?? 30
        let effectiveGrow = hovered.map { noGrow.contains($0) ? 0 : grow } ?? 0
        let widths = Self.widths(naturals: naturals, hovered: hovered,
                                 grow: effectiveGrow, floor: 30)
        var x = bounds.minX
        for (i, sub) in subviews.enumerated() {
            sub.place(at: CGPoint(x: x, y: bounds.minY),
                      proposal: ProposedViewSize(width: widths[i], height: h))
            x += widths[i] + gap
        }
    }

    /// Grow the hovered chip by the FULL `grow` (so its count always fits — no
    /// cap, no overlap) and reclaim that room from its two immediate neighbors,
    /// half from each side, never shrinking a neighbor below `floor`. Whatever
    /// the neighbors can't give is left as a positive total, which makes the
    /// row widen by that small remainder (see `sizeThatFits`) — only in the
    /// rare case that both neighbors are already short. Distant chips are never
    /// shrunk; at most they shift when the row widens.
    static func widths(naturals: [CGFloat], hovered: Int?,
                       grow: CGFloat, floor: CGFloat) -> [CGFloat] {
        var out = naturals
        guard let h = hovered, naturals.indices.contains(h), grow > 0 else { return out }
        var deficit = grow
        let ring = [h + 1, h - 1].filter { naturals.indices.contains($0) }
        if !ring.isEmpty {
            let share = (deficit / CGFloat(ring.count)).rounded()
            for i in ring {
                let take = min(share, deficit, max(0, out[i] - floor))
                out[i] -= take
                deficit -= take
            }
        }
        out[h] = naturals[h] + grow
        return out
    }
}

// MARK: - Chip

/// Capsule chip mirroring HoverPill: natural width NEVER depends on hover —
/// the count is an overlay revealed inside the grown width ChipFlow
/// proposes. Selected = filled with the primary color (inverted text).
private struct TagChip: View {
    let index: Int
    let label: String
    let count: Int?
    let isSelected: Bool
    let isHovered: Bool
    var onHover: (Int, Bool) -> Void
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            .foregroundStyle(isSelected
                             ? AnyShapeStyle(.background)
                             : AnyShapeStyle(isHovered ? .primary : .secondary))
            // Every chip is a pill; unselected ones in quiet dark gray.
            .background(Capsule(style: .continuous)
                .fill(isSelected
                      ? AnyShapeStyle(.primary)
                      : AnyShapeStyle(.primary.opacity(isHovered ? 0.16 : 0.08))))
            .overlay(alignment: .trailing) {
                if isHovered, let count {
                    Text("\(count)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected
                                         ? AnyShapeStyle(.background)
                                         : AnyShapeStyle(.secondary))
                        .padding(.trailing, 14)
                        .transition(.opacity)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
        .onHover { onHover(index, $0) }
        .help(isSelected ? "Clear tag filter" : "Show files tagged \(label)")
    }
}
