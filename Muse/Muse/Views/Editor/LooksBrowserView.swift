//
//  LooksBrowserView.swift
//  Muse
//
//  The Looks tab: presets and LUTs as a grid of thumbnails, each rendered LIVE
//  on the photo currently open. A name in a list tells you nothing about what a
//  look does to YOUR picture; that is the whole reason this replaced the rows.
//
//  The sweep decodes the base proxy ONCE and then runs one `EditRenderer.apply`
//  per look, latest-wins with a debounce. Thumbs are session memory only —
//  never `ThumbnailCache`, never disk: they are per-draft ephemera and would
//  need invalidating on every slider move.
//

import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers

struct LooksBrowserView: View {
    @ObservedObject var session: EditSession
    /// Grid (thumbnails) vs list (rows). Owned by the card so its buttons can
    /// live in the HEADING beside the expander — inside the card they pushed
    /// every look down by a row.
    @Binding var listMode: Bool
    @Environment(\.theme) private var theme
    @EnvironmentObject private var appState: AppState
    @StateObject private var presetStore = EditPresetStore.shared
    @StateObject private var lutStore = LutStore.shared
    @StateObject private var clipboard = EditClipboard.shared

    /// Three across in the 232pt of card the panel leaves: 3×72 + 2×6 = 228.
    /// It was 86, which only ever fitted two.
    static let thumbLongEdge: CGFloat = 72
    /// The list mode's thumbnail — a glance, beside the name.
    static let rowThumbEdge: CGFloat = 28
    /// How far a selected cell's thumbnail pulls in, so the ring frames it.
    /// Matches the grid tile's selection feel.
    static let selectionInset: CGFloat = 5
    static let refreshDebounce: Duration = .milliseconds(400)

    @State private var presetThumbs: [String: CGImage] = [:]
    @State private var lutThumbs: [String: CGImage] = [:]
    /// The photo with NO style on it — the "Original" cell's own preview. It
    /// was a grey slab, which said nothing; this is the thing you're comparing
    /// every look against.
    @State private var originalThumb: CGImage?
    @State private var refreshTask: Task<Void, Never>?
    @State private var sweepGeneration = 0
    /// Which sub-sections are showing their contents.
    @State private var openSections = AppSettings.editorStylesOpen

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Self.thumbLongEdge, maximum: Self.thumbLongEdge),
                  spacing: theme.spacingS)]
    }

    /// The preset currently ON the photo, if any — see EditTransfer.isApplied.
    private var activePreset: EditPresetRow? {
        presetStore.presets.first {
            guard let stack = presetStore.stacks[$0.id] else { return false }
            return EditTransfer.isApplied(stack, onto: session.draft)
        }
    }

    private var activeLut: LutStore.Listing? {
        guard let applied = session.draft.lutParams, !applied.isNeutral else { return nil }
        return lutStore.luts.first { $0.id == applied.lutHash }
    }

    /// What a COLLAPSED section says, so you don't have to open it to know.
    private var presetSummary: String {
        activePreset.map(\.name) ?? String(localized: "Original")
    }

    private var lutSummary: String {
        activeLut.map(\.name) ?? String(localized: "Original")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingM) {
            missingLutNotice

            stylesSection(
                id: "presets",
                title: String(localized: "Presets"),
                summary: presetSummary,
                add: String(localized: "Save current adjustments as a preset"),
                onAdd: { promptForPresetName() }
            ) {
                if presetStore.presets.isEmpty {
                    emptyLine(String(localized: "No presets yet"))
                } else {
                    looks(
                        // "Original" is the photo with no style on it. Without
                        // it there was no way to say "none of these" — every
                        // cell applied something and nothing took it back.
                        original: activePreset == nil,
                        onOriginal: {
                            // Everything a preset can carry. Crop/rotation and
                            // the RAW decode stay — they're the photo, not a
                            // style, and a preset can't set them either.
                            session.draft.setTone { $0 = .neutral }
                            session.draft.setColor { $0 = .neutral }
                            session.draft.setPresence { $0 = .neutral }
                            session.draft.setCurve { $0 = .neutral }
                            session.draft.setToneZone { $0 = .neutral }
                            session.draft.setVignette { $0 = .neutral }
                            session.draft.setHSL { $0 = .neutral }
                            session.draft.setSplitTone { $0 = .neutral }
                            session.draft.setGrain { $0 = .neutral }
                            session.commitGesture()
                        },
                        items: presetStore.presets.map { preset in
                            LookItem(id: preset.id, name: preset.name,
                                     thumb: presetThumbs[preset.id],
                                     isActive: activePreset?.id == preset.id,
                                     apply: { apply(preset) },
                                     actions: presetActions(preset))
                        })
                }
            }

            stylesSection(
                id: "luts",
                title: String(localized: "LUTs"),
                summary: lutSummary,
                add: String(localized: "Import LUTs"),
                onAdd: { importLuts() }
            ) {
                if lutStore.luts.isEmpty {
                    emptyLine(String(localized: "No LUTs imported"))
                } else {
                    looks(
                        original: activeLut == nil,
                        onOriginal: {
                            session.draft.setLut(nil)
                            session.commitGesture()
                        },
                        items: lutStore.luts.map { lut in
                            LookItem(id: lut.id, name: lut.name,
                                     thumb: lutThumbs[lut.id],
                                     isActive: activeLut?.id == lut.id,
                                     apply: { apply(lut) },
                                     actions: lutActions(lut))
                        })
                }
            }

            // The strength slider belongs to the APPLIED LUT, so it appears
            // only once one is on the photo — a disabled slider for a look you
            // haven't chosen is noise. (Removing the LUT is "Original" now.)
            if let lut = session.draft.lutParams, !lut.isNeutral {
                EditSlider(label: String(localized: "LUT Strength"),
                           value: Binding(
                            get: { lut.strength },
                            set: { value in
                                session.draft.setLut(LutParams(lutHash: lut.lutHash,
                                                               name: lut.name,
                                                               strength: value))
                            }),
                           range: 0...1, neutral: 1,
                           onCommit: session.commitGesture)
            }

            Divider()

            LooksActionRow(label: String(localized: "Copy Adjustments"),
                           systemName: "doc.on.doc") {
                clipboard.copy(session.draft,
                               groups: EditTransfer.adjustedGroups(of: session.draft))
            }
            .keyboardShortcut("c", modifiers: [.command, .option])

            LooksActionRow(label: String(localized: "Paste Adjustments"),
                           systemName: "doc.on.clipboard",
                           isEnabled: clipboard.hasContent) {
                session.draft = clipboard.apply(onto: session.draft)
                session.commitGesture()
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
        }
        .task {
            await presetStore.load()
            await lutStore.reload()
            scheduleSweep()
        }
        .onDisappear { refreshTask?.cancel() }
        .onChange(of: session.draft) { _, _ in scheduleSweep() }
        // Keyed on the ids + names rather than the rows: EditPresetRow is a
        // GRDB record, not Equatable, and identity is what a sweep cares about.
        .onChange(of: presetStore.presets.map { $0.id + $0.name }) { _, _ in scheduleSweep() }
        .onChange(of: lutStore.luts) { _, _ in scheduleSweep() }
    }

    // MARK: - Pieces

    /// One look, whichever way it's drawn.
    private struct LookItem: Identifiable {
        let id: String
        let name: String
        let thumb: CGImage?
        let isActive: Bool
        let apply: () -> Void
        let actions: [LookAction]
    }

    /// A collapsible sub-section: chevron + name, the current selection when
    /// closed, and its own ＋. Closed, it still tells you what's applied — the
    /// whole point of collapsing a browser you've already chosen from.
    @ViewBuilder
    private func stylesSection<Content: View>(
        id: String, title: String, summary: String, add: String,
        onAdd: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) -> some View {
        let isOpen = openSections.contains(id)
        VStack(alignment: .leading, spacing: theme.spacingS) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        if isOpen { openSections.remove(id) } else { openSections.insert(id) }
                        AppSettings.editorStylesOpen = openSections
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                        Text(title).font(theme.labelFont)
                        if !isOpen {
                            Text("· \(summary)")
                                .font(theme.labelFont)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(theme.textPrimary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(isOpen ? "Expanded" : summary))

                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(add))
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.panelRaised))

            // Clipped so the reveal doesn't slide over the section above it.
            VStack(spacing: 0) {
                if isOpen {
                    content()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .clipped()
        }
    }

    @ViewBuilder
    private func looks(original: Bool, onOriginal: @escaping () -> Void,
                       items: [LookItem]) -> some View {
        if listMode {
            VStack(spacing: 2) {
                lookRow(name: String(localized: "Original"), thumb: originalThumb,
                        isActive: original, onTap: onOriginal, actions: [])
                ForEach(items) { item in
                    lookRow(name: item.name, thumb: item.thumb, isActive: item.isActive,
                            onTap: item.apply, actions: item.actions)
                }
            }
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: theme.spacingS) {
                originalCell(isActive: original, onTap: onOriginal)
                ForEach(items) { item in
                    lookCell(name: item.name, thumb: item.thumb, isActive: item.isActive,
                             onTap: item.apply) { lookMenu(item.actions) }
                        .lookAccessibilityActions(item.actions)
                }
            }
        }
    }

    /// "Original" as a grid cell — the photo with NO style, rendered like every
    /// other cell so you can actually compare against it.
    private func originalCell(isActive: Bool, onTap: @escaping () -> Void) -> some View {
        lookCell(name: String(localized: "Original"), thumb: originalThumb,
                 isActive: isActive, onTap: onTap) { EmptyView() }
    }

    private func lookRow(name: String, thumb: CGImage?, isActive: Bool,
                         onTap: @escaping () -> Void,
                         actions: [LookAction]) -> some View {
        HStack(spacing: 8) {
            Group {
                if let thumb {
                    Image(decorative: thumb, scale: 1)
                        .resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(theme.panelRaised)
                }
            }
            .frame(width: Self.rowThumbEdge, height: Self.rowThumbEdge)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(name)
                .font(theme.labelFont)
                .foregroundStyle(isActive ? theme.selectionInk : theme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if isActive {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.selectionInk)
            }
            if !actions.isEmpty {
                lookMenuButton(name: name, isActive: isActive, actions: actions)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isActive ? theme.selectionFill : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu { lookMenu(actions) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .lookAccessibilityActions(actions)
    }

    /// A ⋯ button carrying the same menu as the right-click.
    ///
    /// Delete used to be right-click ONLY, which is a gesture with no keyboard,
    /// no VoiceOver and no discoverability. The actions are also published as
    /// accessibility actions on the row itself, so a rotor can reach them.
    private func lookMenuButton(name: String, isActive: Bool,
                                actions: [LookAction]) -> some View {
        Menu {
            lookMenu(actions)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        // `.button` + `.plain`, NOT `.borderlessButton`: that style paints its
        // own content colour and dims it, so the dots came out grey on the
        // selected row no matter where the foregroundStyle was applied. This
        // one renders the label as given.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // Matches the row's LABEL, not a dimmer secondary — the dots and the
        // name are one row and shouldn't read as two weights.
        .foregroundStyle(isActive ? theme.selectionInk : theme.textPrimary)
        .accessibilityLabel(Text("More actions for \(name)"))
    }

    @ViewBuilder
    private func lookMenu(_ actions: [LookAction]) -> some View {
        ForEach(actions) { action in
            if action.isDestructive {
                Divider()
                Button(role: .destructive, action: action.run) { Text(action.title) }
            } else {
                Button(action: action.run) { Text(action.title) }
            }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(theme.labelFont).foregroundStyle(theme.textSecondary)
    }

    private func lookCell(name: String, thumb: CGImage?, isActive: Bool,
                          onTap: @escaping () -> Void,
                          @ViewBuilder menu: () -> some View) -> some View {
        VStack(spacing: 2) {
            // Selected reads like a selected GRID TILE: the thumbnail insets
            // and a blue ring is drawn at the outer edge. The corner checkmark
            // alone was easy to miss at 72pt.
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumb {
                        Image(decorative: thumb, scale: 1)
                            .resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(theme.panelStroke)
                    }
                }
                .frame(width: Self.thumbLongEdge - (isActive ? Self.selectionInset * 2 : 0),
                       height: Self.thumbLongEdge - (isActive ? Self.selectionInset * 2 : 0))
                .clipped()
                // Concentric with the ring: an inset rectangle's radius has to
                // shrink by the inset, or its curve reads rounder than the
                // stroke around it.
                .clipShape(RoundedRectangle(
                    cornerRadius: isActive ? max(2, theme.radius - Self.selectionInset)
                                           : theme.radius,
                    style: .continuous))
                .frame(width: Self.thumbLongEdge, height: Self.thumbLongEdge)
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.controlAccent)
                        .padding(3)
                }
            }
            .frame(width: Self.thumbLongEdge, height: Self.thumbLongEdge)
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: theme.radius, style: .continuous)
                        .strokeBorder(theme.controlAccent, lineWidth: 2.5)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isActive)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .contextMenu { menu() }
            Text(name)
                .font(theme.labelFont)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: Self.thumbLongEdge)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(.isButton)
    }

    /// A stack whose LUT isn't on this Mac renders the ORIGINAL everywhere, so
    /// the editor has to say why rather than let it look like the edit was lost.
    @ViewBuilder
    private var missingLutNotice: some View {
        if let lut = session.draft.lutParams, !lut.isNeutral,
           !lutStore.luts.contains(where: { $0.id == lut.lutHash }) {
            VStack(alignment: .leading, spacing: theme.spacingS) {
                Text("This edit uses a LUT that isn’t on this Mac (\(lut.name)). The photo shows unedited until it’s imported.")
                    .font(theme.labelFont)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { importLuts() } label: { Text("Import…") }
                    .buttonStyle(.plain)
                    .font(theme.labelFont)
                    .foregroundStyle(theme.controlAccent)
            }
            .padding(theme.spacingS)
            .background(theme.panelStroke, in: RoundedRectangle(cornerRadius: theme.radius))
        }
    }

    /// No "Apply": clicking the look already applies it, so the menu item was
    /// a second name for the thing you just did.
    private func presetActions(_ preset: EditPresetRow) -> [LookAction] {
        [LookAction(title: String(localized: "Update from This Photo")) {
            Task { await presetStore.update(id: preset.id, from: session.draft) }
         },
         LookAction(title: String(localized: "Delete Preset"), isDestructive: true) {
            Task { await presetStore.delete(id: preset.id) }
         }]
    }

    private func lutActions(_ lut: LutStore.Listing) -> [LookAction] {
        [LookAction(title: String(localized: "Rename…")) {
            appState.editPromptRequest = EditNamePrompt(
                title: String(localized: "Rename LUT"),
                message: String(localized: "The LUT’s data is unchanged — only its name."),
                placeholder: String(localized: "LUT name"),
                confirmTitle: String(localized: "Rename")) { name in
                    Task { await LutStore.shared.rename(id: lut.id, to: name) }
                }
         },
         LookAction(title: String(localized: "Delete LUT…"), isDestructive: true) {
            confirmDelete(lut)
         }]
    }

    // MARK: - Actions

    private func apply(_ preset: EditPresetRow) {
        guard let stack = EditStackCodec.decode(preset.stack) else { return }
        session.draft = EditTransfer.apply(groups: EditTransfer.adjustedGroups(of: stack),
                                           from: stack, onto: session.draft)
        session.commitGesture()
    }

    private func apply(_ lut: LutStore.Listing) {
        // Re-applying the LUT already on the photo keeps its strength — the
        // click means "this look", not "and start over at 100".
        let strength = session.draft.lutParams?.lutHash == lut.id
            ? (session.draft.lutParams?.strength ?? 1) : 1
        session.draft.setLut(LutParams(lutHash: lut.id, name: lut.name, strength: strength))
        session.commitGesture()
    }

    private func promptForPresetName() {
        let stack = session.draft
        // A preset of NOTHING is Original by another name — it can never show
        // as applied (there is no adjustment to match on) and clicking it does
        // nothing, which is exactly what "it won't let me select it" was.
        guard !EditTransfer.adjustedGroups(of: stack).isEmpty else {
            appState.alertRequest = MuseAlert.message(
                title: String(localized: "Nothing to save yet"),
                message: String(localized: "A preset stores the adjustments on this photo, and this one has none. Move a slider first — or pick Original to go back to no style."))
            return
        }
        appState.editPromptRequest = EditNamePrompt(
            title: String(localized: "Save as New Preset"),
            message: String(localized: "The crop and rotation are not saved with a preset."),
            placeholder: String(localized: "Preset name"),
            confirmTitle: String(localized: "Save")) { name in
                Task { await EditPresetStore.shared.create(name: name, stack: stack) }
            }
    }

    private func importLuts() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "Choose one or more .cube LUT files.")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            let failures = await LutStore.shared.importCubes(at: urls)
            if !failures.isEmpty {
                appState.alertRequest = MuseAlert.message(
                    title: String(localized: "Some LUTs Couldn’t Be Imported"),
                    message: failures
                        .map { "\($0.key): \(String(describing: $0.value))" }
                        .joined(separator: "\n"))
            }
        }
    }

    private func confirmDelete(_ lut: LutStore.Listing) {
        Task {
            let count = await LutStore.shared.referenceCount(id: lut.id)
            appState.alertRequest = MuseAlert.confirm(
                title: String(localized: "Delete “\(lut.name)”?"),
                message: String(localized: "Used by \(count) stored edits — they’ll show their originals until this LUT is imported again."),
                confirmTitle: String(localized: "Delete")) {
                    Task { await LutStore.shared.delete(id: lut.id) }
                }
        }
    }

    // MARK: - Thumbnail sweep

    private func scheduleSweep() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: Self.refreshDebounce)
            guard !Task.isCancelled else { return }
            await runSweep()
        }
    }

    private func runSweep() async {
        sweepGeneration += 1
        let generation = sweepGeneration
        let url = session.url
        let draft = session.draft
        let presets = presetStore.presets
        let luts = lutStore.luts
        let edge = Int(Self.thumbLongEdge * 2)

        let rendered = await Task.detached(priority: .utility) {
            () -> (presets: [String: CGImage], luts: [String: CGImage], original: CGImage?) in
            var presetOut: [String: CGImage] = [:]
            var lutOut: [String: CGImage] = [:]
            var originalOut: CGImage?
            // ONE decode for the whole grid; geometry is applied to the base so
            // every cell shows the crop the user is actually working in.
            guard let base = EditRenderer.decodedProxy(url: url, stack: draft, maxPixel: edge)
            else { return (presetOut, lutOut, originalOut) }
            var geometryOnly = EditStack.fresh()
            if let geo = draft.geometryParams, !geo.isNeutral {
                geometryOnly.setGeometry { $0 = geo }
            }
            let cropped = EditRenderer.apply(geometryOnly, to: base.image,
                                             sourceLongEdge: base.longEdge)
            let longEdge = max(cropped.ciImage.extent.width, cropped.ciImage.extent.height)
            let context = RenderContexts.preview

            // These thumbnails sit beside the live canvas, which renders with
            // headroom. Clipping them would show every Look with blown
            // highlights the canvas doesn't have — the swatch would be lying
            // about what picking it does.
            let headroom = EditRenderer.sourceHeadroom(url: url)

            func render(_ stack: EditStack) -> CGImage? {
                let out = EditRenderer.apply(stack, to: cropped, sourceLongEdge: longEdge)
                let extent = out.ciImage.extent
                guard extent.width >= 1, extent.height >= 1, extent.width.isFinite else { return nil }
                let shown = HDRDecode.toneMappedToSDR(out.ciImage, headroom: headroom)
                return context.createCGImage(shown, from: extent, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }

            originalOut = render(.fresh())
            for preset in presets {
                if Task.isCancelled { return (presetOut, lutOut, originalOut) }
                guard let stack = EditStackCodec.decode(preset.stack) else { continue }
                let candidate = EditTransfer.apply(groups: EditTransfer.adjustedGroups(of: stack),
                                                   from: stack, onto: .fresh())
                if let cg = render(candidate) { presetOut[preset.id] = cg }
            }
            for lut in luts {
                if Task.isCancelled { return (presetOut, lutOut, originalOut) }
                var candidate = EditStack.fresh()
                candidate.setLut(LutParams(lutHash: lut.id, name: lut.name, strength: 1))
                if let cg = render(candidate) { lutOut[lut.id] = cg }
            }
            return (presetOut, lutOut, originalOut)
        }.value

        // Latest wins: a sweep that started before the draft changed must not
        // paint stale thumbs over the newer one's.
        guard generation == sweepGeneration else { return }
        presetThumbs = rendered.presets
        lutThumbs = rendered.luts
        originalThumb = rendered.original
    }
}

/// A full-width row inside the Looks card: label left, glyph right, hover fill.
/// Everything in this card is a row you click, not a word beside a small icon.
private struct LooksActionRow: View {
    let label: String
    let systemName: String
    var accessibilityLabel: String? = nil
    var isEnabled: Bool = true
    var action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label).font(theme.labelFont)
                Spacer(minLength: 0)
                Image(systemName: systemName).font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(theme.textPrimary)
            .opacity(isEnabled ? 1 : 0.4)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering && isEnabled ? theme.panelRaisedHover : theme.panelRaised))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(accessibilityLabel ?? label))
    }
}

/// One entry in a look's menu — the same list drives the right-click menu, the
/// ⋯ button, and the row's VoiceOver actions, so they can't disagree.
private struct LookAction: Identifiable {
    let id = UUID()
    let title: String
    var isDestructive = false
    let run: () -> Void
}

private extension View {
    /// Publishes a look's menu as accessibility actions, so Delete is reachable
    /// without a right-click.
    func lookAccessibilityActions(_ actions: [LookAction]) -> some View {
        var view = AnyView(self)
        for action in actions {
            view = AnyView(view.accessibilityAction(named: Text(action.title), action.run))
        }
        return view
    }
}
