//
//  ViewerInfoColumn.swift
//  Muse
//
//  The hero viewer's right-hand info column: filename + file info line,
//  then Collection / Tags / Colors cards and the Open in Finder / Delete
//  actions row. Mutations go through TagStore / CollectionStore and then
//  call the parent-supplied refresh() to reload ViewerFileDetails.
//  Navigation (tag search, collection filter, delete) is delegated to the
//  parent via callbacks — Task 9 wires them.
//

import SwiftUI
import AppKit
import GRDB

struct ViewerInfoColumn<Chrome: View>: View {
    let url: URL
    let details: ViewerFileDetails?
    /// Shown when the DB has no palette yet (computed on open by the viewer).
    var fallbackPalette: [String] = []
    /// True while the viewer is still resolving a palette for the current
    /// file. Renders the colors card with placeholder swatches so the
    /// actions row doesn't jump down when the real swatches arrive.
    var paletteLoading: Bool = false
    /// Near-opaque card drawn behind the whole column while zoomed. It's the
    /// direct background of the content stack, so it resizes in the same
    /// layout pass (and spring) as the Collection/Tags expanders.
    var backing: Color = .black
    var backingVisible: Bool = false
    var refresh: () async -> Void
    var onTagTap: (String) -> Void
    var onCollectionTap: (String) -> Void
    var onOpenInFinder: () -> Void
    var onDelete: () -> Void
    @Binding var toast: ToastData?
    /// The viewer's chrome row (zoom pill / Fit / ✕) — first row of the
    /// column so the backing card covers it too.
    @ViewBuilder var chrome: () -> Chrome

    @ObservedObject private var engine = CollectionsEngine.shared
    @State private var hoveredCollectionPill: Int?
    @State private var hoveredTagPill: Int?
    @State private var collectionsExpanded = false
    @State private var tagsExpanded = false
    @State private var newCollectionName = ""
    @State private var newTagLabel = ""
    @State private var tagSuggestions: [PillItem] = []

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                chrome()
                    .padding(.bottom, 12)   // 14 + 12 = 26 down to the name
                header
                collectionCard
                tagsCard
                if !displayPalette.isEmpty {
                    colorsCard(palette: displayPalette)
                } else if paletteLoading {
                    colorsPlaceholderCard
                }
                actionsRow
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(backing.opacity(0.92))
                    .opacity(backingVisible ? 1 : 0)
                    // In fast (0.08s) so the card lands before the 0.15s
                    // zoom finishes; out unhurried. Size changes need no
                    // animation here — the card is layout-bound to the
                    // content, so it moves with the expander springs.
                    .animation(backingVisible ? .easeOut(duration: 0.08)
                                              : .easeOut(duration: 0.3),
                               value: backingVisible)
            )
        }
        .frame(width: 258 + 24)
    }

    /// Analyzed palette from the DB when present, else the on-open fallback.
    private var displayPalette: [String] {
        if let palette = details?.palette, !palette.isEmpty { return palette }
        return fallbackPalette
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(url.lastPathComponent)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(2)
            Text(infoLine)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var infoLine: String {
        var parts: [String] = []
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if let bytes = details?.sizeBytes ?? (values?.fileSize).map(Int64.init) {
            let f = ByteCountFormatter()
            f.allowedUnits = .useMB
            f.countStyle = .file
            parts.append(f.string(fromByteCount: bytes))
        }
        if let px = details?.pixelSize {
            parts.append("\(Int(px.width))×\(Int(px.height)) px")
        }
        if let date = values?.contentModificationDate {
            let df = DateFormatter()
            df.dateStyle = .medium
            parts.append(df.string(from: date))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Collection card

    private var collectionCard: some View {
        PillCard(title: "COLLECTION",
                 pills: (details?.collections ?? []).map { PillItem(id: $0.id, label: $0.name) },
                 hovered: $hoveredCollectionPill,
                 isExpanded: $collectionsExpanded,
                 onPillTap: { onCollectionTap($0.id) },
                 onPillRemove: { pill in
                     mutate { queue, fileID in
                         try await CollectionStore.removeFile(queue: queue, fileID: fileID,
                                                              collectionID: pill.id)
                         await engine.reload()
                         show("Removed from \(pill.label)")
                     }
                 }) {
            CardExpander(candidates: collectionCandidates,
                         placeholder: "…or create a new one",
                         text: $newCollectionName,
                         onCandidateTap: { candidate in
                             mutate { queue, fileID in
                                 try await CollectionStore.addFile(queue: queue, fileID: fileID,
                                                                   collectionID: candidate.id)
                                 await engine.reload()
                                 show("Added to \(candidate.label)")
                             }
                         },
                         onCreate: { name in
                             mutate { queue, fileID in
                                 _ = try await CollectionStore.createManual(queue: queue, name: name,
                                                                            fileID: fileID)
                                 await engine.reload()
                                 show("Added to \(name)")
                             }
                         })
        }
    }

    /// Visible collections that do NOT already contain this file.
    private var collectionCandidates: [PillItem] {
        let memberIDs = Set((details?.collections ?? []).map(\.id))
        return engine.collections
            .map(\.collection)
            .filter { !memberIDs.contains($0.id) }
            .map { PillItem(id: $0.id, label: $0.name) }
    }

    // MARK: - Tags card

    private var tagsCard: some View {
        PillCard(title: "TAGS",
                 pills: (details?.tags ?? []).map { PillItem(id: $0.id, label: $0.label) },
                 hovered: $hoveredTagPill,
                 isExpanded: $tagsExpanded,
                 onPillTap: { onTagTap($0.label) },
                 onPillRemove: { pill in
                     guard let tag = details?.tags.first(where: { $0.id == pill.id }) else { return }
                     Task {
                         _ = await TagStore.shared.removeTag(tag, for: url)
                         await refresh()
                         show("Removed \(pill.label)")
                     }
                 }) {
            CardExpander(candidates: tagSuggestions,
                         placeholder: "…or create a new one",
                         text: $newTagLabel,
                         onCandidateTap: { candidate in
                             Task {
                                 _ = await TagStore.shared.addManualTag(label: candidate.label, for: url)
                                 await refresh()
                                 await loadTagSuggestions()
                                 show("Added \(candidate.label)")
                             }
                         },
                         onCreate: { label in
                             Task {
                                 _ = await TagStore.shared.addManualTag(label: label, for: url)
                                 await refresh()
                                 show("Added \(label)")
                             }
                         })
            .task { await loadTagSuggestions() }
        }
    }

    /// Most-used tag labels across the library that aren't already on this file.
    private func loadTagSuggestions() async {
        guard let queue = Database.shared.dbQueue else { return }
        let current = Set((details?.tags ?? []).map(\.label))
        let labels: [String] = (try? await queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT label FROM tags GROUP BY label ORDER BY COUNT(*) DESC LIMIT 24
                """)
        }) ?? []
        tagSuggestions = labels
            .filter { !current.contains($0) }
            .prefix(12)
            .map { PillItem(id: $0, label: $0) }
    }

    // MARK: - Colors card

    private func colorsCard(palette: [String]) -> some View {
        InfoCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardLabel(text: "COLORS")
                    Spacer()
                    HoverTextButton(label: "copy all") {
                        copyToPasteboard(palette.joined(separator: ", "))
                        show("Copied \(palette.count) colors")
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 26, maximum: 26), spacing: 6)],
                          alignment: .leading, spacing: 6) {
                    ForEach(palette, id: \.self) { hex in
                        ColorSwatch(hex: hex) {
                            copyToPasteboard(hex)
                            show("Copied \(hex)")
                        }
                    }
                }
            }
        }
    }

    /// Same shell and geometry as colorsCard so nothing below moves when
    /// real swatches replace the placeholders.
    private var colorsPlaceholderCard: some View {
        InfoCard {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(text: "COLORS")
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(0.08))
                            .frame(width: 26, height: 26)
                    }
                }
            }
        }
    }

    // MARK: - Actions row

    private var actionsRow: some View {
        HStack(spacing: 8) {
            ActionButton(label: "Open in Finder", systemImage: "folder", action: onOpenInFinder)
            ActionButton(label: "Delete", systemImage: "trash", action: onDelete)
        }
    }

    // MARK: - Helpers

    /// Runs a DB mutation that needs the queue + fileID, then refreshes details.
    private func mutate(_ work: @escaping (DatabaseQueue, String) async throws -> Void) {
        guard let queue = Database.shared.dbQueue, let fileID = details?.fileID else { return }
        Task {
            try? await work(queue, fileID)
            await refresh()
        }
    }

    private func show(_ message: String) {
        withAnimation(.easeOut(duration: 0.18)) { toast = ToastData(message: message) }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Building blocks

struct PillItem: Identifiable, Equatable {
    var id: String
    var label: String
}

/// Rounded translucent card shell: radius 14, white 0.09 fill, 13/14 padding.
private struct InfoCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 13)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.09)))
    }
}

private struct CardLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .textCase(.uppercase)
            .foregroundStyle(.white.opacity(0.42))
    }
}

/// Card with a label row + ＋ expander button, HoverPill flow, and an
/// expander section that springs open below the pills.
private struct PillCard<Expander: View>: View {
    let title: String
    let pills: [PillItem]
    @Binding var hovered: Int?
    @Binding var isExpanded: Bool
    var onPillTap: (PillItem) -> Void
    var onPillRemove: (PillItem) -> Void
    @ViewBuilder var expander: () -> Expander

    var body: some View {
        InfoCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardLabel(text: title)
                    Spacer()
                    PlusCircleButton(size: 18, rotated: isExpanded,
                                     accessibilityLabel: isExpanded ? "Hide \(title.lowercased()) field"
                                                                    : "Add \(title.lowercased())") {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                            isExpanded.toggle()
                        }
                    }
                }
                if pills.isEmpty {
                    Text("None yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                } else {
                    PillFlow(gap: 6, hovered: hovered) {
                        ForEach(Array(pills.enumerated()), id: \.element.id) { i, pill in
                            HoverPill(index: i, label: pill.label, isHovered: hovered == i,
                                      onHover: { idx, inside in
                                          if inside { hovered = idx }
                                          else if hovered == idx { hovered = nil }
                                      },
                                      onTap: { onPillTap(pill) },
                                      onRemove: { onPillRemove(pill) })
                        }
                    }
                    .animation(.easeOut(duration: 0.18), value: hovered)
                }
                if isExpanded {
                    expander()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Expander body: dashed candidate pills (tap to add) + create-new field.
private struct CardExpander: View {
    let candidates: [PillItem]
    let placeholder: String
    @Binding var text: String
    var onCandidateTap: (PillItem) -> Void
    var onCreate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !candidates.isEmpty {
                PillFlow(gap: 6, hovered: nil) {
                    ForEach(candidates) { candidate in
                        DashedPill(label: candidate.label) { onCandidateTap(candidate) }
                    }
                }
            }
            HStack(spacing: 6) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.08)))
                    .onSubmit(submit)
                PlusCircleButton(size: 18, rotated: false,
                                 accessibilityLabel: "Create", action: submit)
            }
        }
    }

    private func submit() {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        text = ""
        onCreate(name)
    }
}

private struct DashedPill: View {
    let label: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.65))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(.white.opacity(hovering ? 0.55 : 0.3))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PlusCircleButton: View {
    let size: CGFloat
    let rotated: Bool
    var accessibilityLabel: String = "Add"
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 1.0 : 0.7))
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(hovering ? 0.28 : 0.14)))
                .rotationEffect(.degrees(rotated ? 45 : 0))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering = $0 }
    }
}

private struct HoverTextButton: View {
    let label: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hovering ? .white : .white.opacity(0.45))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ColorSwatch: View {
    let hex: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color)
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.white.opacity(hovering ? 0.6 : 0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(hex)
    }

    private var color: Color {
        guard let (r, g, b) = NamedColor.parse(hex) else { return .gray }
        return Color(red: r, green: g, blue: b)
    }
}

private struct ActionButton: View {
    let label: String
    let systemImage: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.92))
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(hovering ? 0.22 : 0.09)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
