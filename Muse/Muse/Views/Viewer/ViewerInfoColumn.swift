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
    /// Extra file metadata (EXIF / PDF / A/V) shown in the INFO card. Loaded by
    /// the hero viewer on open; nil/empty → the card is omitted.
    var metadata: FileMetadata? = nil
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
    @EnvironmentObject private var appState: AppState
    @State private var hoveredCollectionPill: Int?
    @State private var hoveredTagPill: Int?
    @State private var collectionsExpanded = false
    @State private var tagsExpanded = false
    /// INFO card defaults to OPEN (rows visible, button shows ×); tapping
    /// collapses it (button shows +), mirroring the tags card's motion.
    @State private var infoExpanded = true
    @State private var newCollectionName = ""
    @State private var newTagLabel = ""
    @State private var tagSuggestions: [PillItem] = []
    /// Note card: default collapsed when empty, expanded when it has text.
    @State private var noteExpanded = false
    /// Local draft — never bound to AppState. Committed on blur / collapse / file switch.
    @State private var noteDraft = ""
    /// The note value we last seeded the draft from, so commit only writes on change.
    @State private var loadedNote = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                chrome()
                    .padding(.bottom, 12)   // 14 + 12 = 26 down to the name
                header
                collectionCard
                tagsCard
                ratingCard
                noteCard
                if !displayPalette.isEmpty {
                    colorsCard(palette: displayPalette)
                } else if paletteLoading {
                    colorsPlaceholderCard
                }
                if let metadata, !metadata.rows.isEmpty {
                    infoCard(metadata)
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
        // Just size · dimensions here — dates live in the INFO card now, where
        // they're labeled (Taken / Modified), so there's no ambiguous bare date.
        var parts: [String] = []
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let bytes = details?.sizeBytes ?? (values?.fileSize).map(Int64.init) {
            let f = ByteCountFormatter()
            f.allowedUnits = .useMB
            f.countStyle = .file
            parts.append(f.string(fromByteCount: bytes))
        }
        if let px = details?.pixelSize {
            parts.append("\(Int(px.width))×\(Int(px.height)) px")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Collection card

    private var collectionCard: some View {
        PillCard(title: String(localized: "COLLECTION"),
                 pills: (details?.collections ?? []).map { PillItem(id: $0.id, label: $0.name) },
                 hovered: $hoveredCollectionPill,
                 isExpanded: $collectionsExpanded,
                 onPillTap: { onCollectionTap($0.id) },
                 onPillRemove: { pill in
                     mutate { queue, fileID in
                         try await CollectionStore.removeFile(queue: queue, fileID: fileID,
                                                              collectionID: pill.id)
                         await engine.reload()
                         // Keep the OPEN collection's grid in sync — the grid
                         // renders activeCollectionFiles, so a store-only
                         // removal leaves the tile ghosting behind the viewer
                         // (and riding into export/share). Mirrors
                         // AppState.removeFromCollection's bookkeeping.
                         if appState.activeCollectionID == pill.id {
                             appState.dropFromActiveCollection(
                                 path: url.standardizedFileURL.path)
                             if appState.activeCollectionFiles?.isEmpty == true {
                                 appState.setActiveCollection(nil)
                             } else {
                                 appState.reloadTagChips()
                             }
                         }
                         show(String(localized: "Removed from \(pill.label)"))
                     }
                 }) {
            CardExpander(candidates: collectionCandidates,
                         placeholder: String(localized: "…or create a new one"),
                         text: $newCollectionName,
                         onCandidateTap: { candidate in
                             mutate { queue, fileID in
                                 try await CollectionStore.addFile(queue: queue, fileID: fileID,
                                                                   collectionID: candidate.id)
                                 await engine.reload()
                                 show(String(localized: "Added to \(candidate.label)"))
                             }
                         },
                         onCreate: { name in
                             mutate { queue, fileID in
                                 _ = try await CollectionStore.createManual(queue: queue, name: name,
                                                                            fileID: fileID)
                                 await engine.reload()
                                 show(String(localized: "Added to \(name)"))
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
        PillCard(title: String(localized: "TAGS"),
                 // Star-rating glyph tags are shown in the RATING card below, not
                 // here — filter them out so the file's rating isn't duplicated as
                 // a removable "tag" pill.
                 pills: (details?.tags ?? []).filter { !StarRating.isRating($0.label) }
                     .map { PillItem(id: $0.id, label: $0.label) },
                 hovered: $hoveredTagPill,
                 isExpanded: $tagsExpanded,
                 onPillTap: { onTagTap($0.label) },
                 onPillRemove: { pill in
                     guard let tag = details?.tags.first(where: { $0.id == pill.id }) else { return }
                     Task {
                         _ = await TagStore.shared.removeTag(tag, for: url)
                         await refresh()
                         // Every tag mutation must bump tagsVersion (grid-side
                         // paths all do) — it re-derives the chip row, counts,
                         // and the right-click Add Tag list; without it a
                         // filtered-out tag's tile lingers until an unrelated
                         // edit.
                         appState.tagsVersion &+= 1
                         show(String(localized: "Removed \(VocabularyLocalizer.shared.display(pill.label))"))
                     }
                 }) {
            CardExpander(candidates: tagSuggestions,
                         placeholder: String(localized: "…or create a new one"),
                         text: $newTagLabel,
                         onCandidateTap: { candidate in
                             Task {
                                 _ = await TagStore.shared.addManualTag(label: candidate.label, for: url)
                                 await refresh()
                                 await loadTagSuggestions()
                                 appState.tagsVersion &+= 1
                                 show(String(localized: "Added \(VocabularyLocalizer.shared.display(candidate.label))"))
                             }
                         },
                         onCreate: { label in
                             Task {
                                 _ = await TagStore.shared.addManualTag(label: label, for: url)
                                 await refresh()
                                 appState.tagsVersion &+= 1
                                 show(String(localized: "Added \(label)"))
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
            .filter { !current.contains($0) && !StarRating.isRating($0) }
            .prefix(12)
            .map { PillItem(id: $0, label: $0) }
    }

    // MARK: - Rating card

    /// Current rating derived from the file's tags (the first rating-glyph tag).
    private var currentRating: Int? {
        (details?.tags ?? []).compactMap { StarRating.rating(from: $0.label) }.max()
    }

    /// Shows the rating UNDER Tags (owner). Interactive: tap star N to set N; tap
    /// the current rating to remove it (mirrors the context menu). Mutually
    /// exclusive via TagStore.setRating; bumps tagsVersion like every hero tag
    /// edit so the grid chips + badge refresh.
    private var ratingCard: some View {
        InfoCard {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(text: String(localized: "RATING"))
                HStack(spacing: 4) {
                    ForEach(1...StarRating.maxStars, id: \.self) { n in
                        let filled = (currentRating ?? 0) >= n
                        Button {
                            setRating(currentRating == n ? nil : n)
                        } label: {
                            Image(systemName: filled ? "star.fill" : "star")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white.opacity(filled ? 0.95 : 0.35))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(String(format: NSLocalizedString(
                            "%lld-star rating",
                            comment: "VoiceOver: star rating of a photo"), n)))
                    }
                }
            }
        }
    }

    private func setRating(_ stars: Int?) {
        Task {
            await TagStore.shared.setRating(stars, forURLs: [url])
            await refresh()
            appState.tagsVersion &+= 1
            show(stars == nil
                 ? String(localized: "Rating removed")
                 : String(localized: "Rated \(stars!) stars"))
        }
    }

    // MARK: - Note card

    /// A user-authored free-text note, per file-in-folder. Collapsible (default
    /// collapsed when empty, expanded when it has text). The draft is local and
    /// commits on blur / collapse / file switch — never per keystroke.
    private var noteCard: some View {
        InfoCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardLabel(text: String(localized: "NOTE"))
                    Spacer()
                    Button {
                        copyToPasteboard(noteDraft)
                        show(String(localized: "Note copied"))
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(String(localized: "Copy note"))
                    PlusCircleButton(size: 18, rotated: noteExpanded,
                                     accessibilityLabel: noteExpanded ? String(localized: "Hide note")
                                                                      : String(localized: "Show note")) {
                        // Collapsing commits any pending edit first.
                        if noteExpanded { commitNote(to: url) }
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                            noteExpanded.toggle()
                        }
                    }
                }
                if noteExpanded {
                    TextField(String(localized: "Add a note…"), text: $noteDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...8)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(0.08)))
                        .focused($noteFocused)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Seed the draft when the loaded note changes (details arrive async after
        // a file switch). Don't stomp an in-progress edit.
        .onChange(of: details?.note) { _, newValue in
            let value = newValue ?? ""
            loadedNote = value
            if !noteFocused {
                noteDraft = value
                noteExpanded = !value.isEmpty
            }
        }
        // File switched (e.g. arrow keys) while editing: flush to the OLD file first.
        .onChange(of: url) { oldURL, _ in
            commitNote(to: oldURL)
        }
        // Blur commits.
        .onChange(of: noteFocused) { _, focused in
            if !focused { commitNote(to: url) }
        }
        .onDisappear { commitNote(to: url) }
        .task(id: url) {
            let value = details?.note ?? ""
            loadedNote = value
            noteDraft = value
            noteExpanded = !value.isEmpty
        }
    }

    /// Write the draft to `target` only if it changed from the loaded value.
    private func commitNote(to target: URL) {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != loadedNote.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        loadedNote = trimmed
        Task {
            await TagStore.shared.setNote(trimmed, forURL: target)
            await refresh()
        }
    }

    // MARK: - Colors card

    private func colorsCard(palette: [String]) -> some View {
        InfoCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardLabel(text: String(localized: "COLORS"))
                    Spacer()
                    HoverTextButton(label: String(localized: "copy all")) {
                        copyToPasteboard(palette.joined(separator: ", "))
                        show(String(localized: "Copied \(palette.count) colors"))
                    }
                    .accessibilityLabel("Copy all colors")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 26, maximum: 26), spacing: 6)],
                          alignment: .leading, spacing: 6) {
                    ForEach(palette, id: \.self) { hex in
                        ColorSwatch(hex: hex) {
                            copyToPasteboard(hex)
                            show(String(localized: "Copied \(hex)"))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Info card

    private func infoCard(_ metadata: FileMetadata) -> some View {
        InfoCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardLabel(text: String(localized: "INFO"))
                    Spacer()
                    PlusCircleButton(size: 18, rotated: infoExpanded,
                                     accessibilityLabel: infoExpanded ? String(localized: "Hide info") : String(localized: "Show info")) {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                            infoExpanded.toggle()
                        }
                    }
                }
                if infoExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(metadata.rows) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                // row.label is canonical English (also used as a
                                // comparison key in FileMetadata); localize for
                                // display via a runtime catalog lookup. Wider
                                // column so longer French labels don't truncate.
                                Text(NSLocalizedString(row.label, comment: "INFO card metadata label"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.42))
                                    .frame(width: 80, alignment: .leading)
                                Text(row.value)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if let coord = metadata.coordinate {
                            OpenInMapsButton(coordinate: coord)
                                .padding(.top, 2)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Same shell and geometry as colorsCard so nothing below moves when
    /// real swatches replace the placeholders.
    private var colorsPlaceholderCard: some View {
        InfoCard {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(text: String(localized: "COLORS"))
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(0.08))
                            .frame(width: 26, height: 26)
                            // Transient loading placeholders — nothing to announce.
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    // MARK: - Actions row

    private var actionsRow: some View {
        HStack(spacing: 8) {
            // Finder fills the leftover width; Delete hugs its own (short) label,
            // so the long French "Ouvrir dans le Finder" gets the room it needs
            // instead of being squeezed into a forced 50/50 split.
            ActionButton(label: String(localized: "Open in Finder"), systemImage: "folder", fillsWidth: true, action: onOpenInFinder)
            ActionButton(label: String(localized: "Delete"), systemImage: "trash", isDestructive: true, action: onDelete)
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
            // Every card title (COLLECTION / TAGS / COLORS / INFO) is a heading,
            // so VoiceOver's heading rotor can jump between the column's cards.
            .accessibilityAddTraits(.isHeader)
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
                                     accessibilityLabel: isExpanded ? String(localized: "Hide \(title.lowercased()) field")
                                                                    : String(localized: "Add \(title.lowercased())")) {
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
                            // Display the localized label; taps/removal use the
                            // canonical `pill.label`/`pill.id` (unchanged). `display`
                            // is identity for non-vocabulary strings (collection
                            // names), so this shared render site is safe for both.
                            let pillLabel = VocabularyLocalizer.shared.display(pill.label)
                            HoverPill(index: i, label: pillLabel, isHovered: hovered == i,
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
                        // Display the localized vision-tag term; the tap keeps
                        // the canonical `candidate.label` for the DB write. `display`
                        // is identity for non-vocabulary strings (collection names).
                        DashedPill(label: VocabularyLocalizer.shared.display(candidate.label)) { onCandidateTap(candidate) }
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
                                 accessibilityLabel: String(localized: "Create"), action: submit)
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
    var accessibilityLabel: String = String(localized: "Add")
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: rotated ? "minus" : "plus")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 1.0 : 0.7))
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(hovering ? 0.28 : 0.14)))
                .contentTransition(.identity)
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

/// "Open in Maps" link-button: an underlined label + a small upper-right arrow
/// so it reads as an action without being a heavy filled button. Hands off to
/// Maps.app via a `maps://` URL (no in-app map — that would be a network fetch).
private struct OpenInMapsButton: View {
    let coordinate: Coordinate
    @State private var hovering = false

    var body: some View {
        Button {
            let u = String(format: "maps://?ll=%.6f,%.6f", coordinate.lat, coordinate.long)
            if let url = URL(string: u) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 4) {
                Text("Open in Maps").underline()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(hovering ? .white : .white.opacity(0.7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Open location in Maps")
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
        // Swatch has no text; name it after its action (tapping copies the hex).
        .accessibilityLabel("Copy color \(hex)")
    }

    private var color: Color {
        guard let (r, g, b) = NamedColor.parse(hex) else { return .gray }
        return Color(red: r, green: g, blue: b)
    }
}

private struct ActionButton: View {
    let label: String
    let systemImage: String
    /// When true the button greedily fills the leftover row width; when false it
    /// hugs its own intrinsic label width. The primary (Finder) button fills so
    /// long localized labels get the room; the secondary (Delete) button hugs.
    var fillsWidth: Bool = false
    /// Destructive actions (Delete) get a red glyph/label + red hover wash so the
    /// irreversible action reads distinct from the neutral Finder button.
    var isDestructive: Bool = false
    var action: () -> Void
    @State private var hovering = false

    /// Coral-leaning red — brighter than systemRed so it stays legible over the
    /// hero viewer's darkened adaptive wash.
    private var tint: Color {
        isDestructive ? Color(red: 1.0, green: 0.45, blue: 0.42) : .white
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    // The text label names the button; the glyph is decorative.
                    .accessibilityHidden(true)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Belt-and-suspenders for an unusually long label: shrink to
                    // fit before truncating so text never spills past the capsule.
                    .minimumScaleFactor(0.7)
            }
            // Label/icon stay white for legibility; the red identity comes from
            // the outline alone (red text over the dark wash read poorly).
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 10)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                // Neutral keeps the faint white wash; destructive carries a light
                // red tint so the fill nods to the outline without overpowering.
                .fill(tint.opacity(isDestructive ? (hovering ? 0.30 : 0.16)
                                                  : (hovering ? 0.22 : 0.09))))
            // Destructive button reads as red via a solid (full-opacity) outline
            // rather than a heavy fill, so it stays distinct without overpowering.
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isDestructive ? tint : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
