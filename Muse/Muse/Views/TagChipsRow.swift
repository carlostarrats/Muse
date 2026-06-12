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
                    ChipFlow(gap: 8, hovered: hovered, grow: 30, noGrow: [0]) {
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
                // Resting 24 is breathing room above the collections row.
                // Filtered, the collections are gone and the grid rises to
                // where the cards sit: 24 + row's 10 − grid's own 20 inset.
                .padding(.bottom, appState.activeTagLabel != nil ? 14 : 24)
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
            Text("The tag is removed from every image. Your images stay on disk.")
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
        Task { @MainActor in
            await TagStore.shared.deleteLabel(label)
            if appState.activeTagLabel == label { appState.setActiveTag(nil) }
            appState.tagsVersion += 1
        }
    }

    private func hover(_ index: Int, _ inside: Bool) {
        if inside { hovered = index }
        else if hovered == index { hovered = nil }
    }

    /// Reload when tags mutate, the sidebar selection changes, or the
    /// folder's contents land/refresh.
    private var reloadKey: String {
        "\(appState.tagsVersion)|\(appState.selectedFolder?.url.path ?? "")|\(appState.currentFiles.count)"
    }

    /// Tag labels (with counts) for EXACTLY the files the grid can show.
    /// Deriving from currentFiles — not a DB folder query — means a chip
    /// can never filter down to an empty grid: a tag with no visible
    /// images simply has no chip.
    private func loadLabels() async {
        guard let q = Database.shared.dbQueue else { return }
        let paths = appState.currentFiles.map { $0.url.standardizedFileURL.path }
        guard !paths.isEmpty else {
            tags = []
            return
        }
        var counts: [String: Int] = [:]
        for start in stride(from: 0, to: paths.count, by: 500) {
            let chunk = Array(paths[start..<min(start + 500, paths.count)])
            let rows: [(String, Int)] = (try? await q.read { db in
                let marks = databaseQuestionMarks(count: chunk.count)
                return try Row.fetchAll(db, sql: """
                    SELECT t.label, COUNT(DISTINCT t.file_id) AS c
                    FROM tags t JOIN paths p ON p.file_id = t.file_id
                    WHERE p.is_alive = 1 AND p.absolute_path IN (\(marks))
                    GROUP BY t.label
                    """, arguments: StatementArguments(chunk)).map { ($0["label"], $0["c"]) }
            }) ?? []
            for (label, count) in rows { counts[label, default: 0] += count }
        }
        tags = counts.sorted { $0.value > $1.value }.prefix(30)
            .map { (label: $0.key, count: $0.value) }
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
        naturalSize(subviews)   // hover-independent: the row never reflows
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let naturals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let h = subviews.first?.sizeThatFits(.unspecified).height ?? 30
        let effectiveGrow = hovered.map { noGrow.contains($0) ? 0 : grow } ?? 0
        let widths = Self.widths(naturals: naturals, hovered: hovered,
                                 grow: effectiveGrow, floor: 50)
        var x = bounds.minX
        for (i, sub) in subviews.enumerated() {
            sub.place(at: CGPoint(x: x, y: bounds.minY),
                      proposal: ProposedViewSize(width: widths[i], height: h))
            x += widths[i] + gap
        }
    }

    /// Steal `grow` from the hovered chip's neighbors, alternating one step
    /// out per side, never below `floor`. The hovered chip grows by exactly
    /// what was stolen, so the row total is invariant.
    static func widths(naturals: [CGFloat], hovered: Int?,
                       grow: CGFloat, floor: CGFloat) -> [CGFloat] {
        var out = naturals
        guard let h = hovered, naturals.indices.contains(h), grow > 0 else { return out }
        // ONLY the two immediate neighbors give space — half each, capped
        // at their floor. Never spill further out: a 1pt steal still
        // truncates a chip's text, so distant chips must stay untouched.
        // Any shortfall just shrinks the hovered chip's growth instead.
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
        out[h] = naturals[h] + (grow - max(0, deficit))
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
