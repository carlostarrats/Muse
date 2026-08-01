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
    @Environment(\.theme) private var theme
    @EnvironmentObject private var appState: AppState
    @StateObject private var presetStore = EditPresetStore.shared
    @StateObject private var lutStore = LutStore.shared
    @StateObject private var clipboard = EditClipboard.shared

    static let thumbLongEdge: CGFloat = 86
    static let refreshDebounce: Duration = .milliseconds(400)

    @State private var presetThumbs: [String: CGImage] = [:]
    @State private var lutThumbs: [String: CGImage] = [:]
    @State private var refreshTask: Task<Void, Never>?
    @State private var sweepGeneration = 0

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Self.thumbLongEdge), spacing: theme.spacingS)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingM) {
            missingLutNotice

            sectionHeader(String(localized: "Presets")) { promptForPresetName() }
            if presetStore.presets.isEmpty {
                emptyLine(String(localized: "No presets yet"))
            } else {
                LazyVGrid(columns: columns, spacing: theme.spacingS) {
                    ForEach(presetStore.presets) { preset in
                        lookCell(name: preset.name, thumb: presetThumbs[preset.id],
                                 isActive: false) {
                            apply(preset)
                        } menu: {
                            presetMenu(preset)
                        }
                    }
                }
            }

            sectionHeader(String(localized: "LUTs")) { importLuts() }
            if lutStore.luts.isEmpty {
                emptyLine(String(localized: "No LUTs imported"))
            } else {
                LazyVGrid(columns: columns, spacing: theme.spacingS) {
                    ForEach(lutStore.luts) { lut in
                        lookCell(name: lut.name, thumb: lutThumbs[lut.id],
                                 isActive: session.draft.lutParams?.lutHash == lut.id) {
                            apply(lut)
                        } menu: {
                            lutMenu(lut)
                        }
                    }
                }
            }

            // The strength slider belongs to the APPLIED LUT, so it appears
            // only once one is on the photo — a disabled slider for a look you
            // haven't chosen is noise.
            if let lut = session.draft.lutParams {
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
                Button {
                    session.draft.setLut(nil)
                    session.commitGesture()
                } label: { Text("Remove LUT") }
                    .buttonStyle(.plain)
                    .font(theme.labelFont)
                    .foregroundStyle(theme.textSecondary)
            }

            Divider()

            Button {
                clipboard.copy(session.draft,
                               groups: EditTransfer.adjustedGroups(of: session.draft))
            } label: { Text("Copy Adjustments") }
                .font(theme.labelFont)
                .buttonStyle(.plain)
                .keyboardShortcut("c", modifiers: [.command, .option])

            Button {
                session.draft = clipboard.apply(onto: session.draft)
                session.commitGesture()
            } label: { Text("Paste Adjustments") }
                .font(theme.labelFont)
                .buttonStyle(.plain)
                .disabled(!clipboard.hasContent)
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

    private func sectionHeader(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(theme.labelFont).foregroundStyle(theme.textSecondary)
            Spacer()
            Button(action: action) { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(title))
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(theme.labelFont).foregroundStyle(theme.textSecondary)
    }

    private func lookCell(name: String, thumb: CGImage?, isActive: Bool,
                          onTap: @escaping () -> Void,
                          @ViewBuilder menu: () -> some View) -> some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                if let thumb {
                    Image(decorative: thumb, scale: 1)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: Self.thumbLongEdge, height: Self.thumbLongEdge)
                        .clipped()
                } else {
                    Rectangle().fill(theme.panelStroke)
                        .frame(width: Self.thumbLongEdge, height: Self.thumbLongEdge)
                }
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.controlAccent)
                        .padding(3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.radius, style: .continuous))
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

    @ViewBuilder
    private func presetMenu(_ preset: EditPresetRow) -> some View {
        Button { apply(preset) } label: { Text("Apply") }
        Button {
            Task { await presetStore.update(id: preset.id, from: session.draft) }
        } label: { Text("Update from This Photo") }
        Button(role: .destructive) {
            Task { await presetStore.delete(id: preset.id) }
        } label: { Text("Delete") }
    }

    @ViewBuilder
    private func lutMenu(_ lut: LutStore.Listing) -> some View {
        Button { apply(lut) } label: { Text("Apply") }
        Button {
            appState.editPromptRequest = EditNamePrompt(
                title: String(localized: "Rename LUT"),
                message: String(localized: "The LUT’s data is unchanged — only its name."),
                placeholder: String(localized: "LUT name"),
                confirmTitle: String(localized: "Rename")) { name in
                    Task { await LutStore.shared.rename(id: lut.id, to: name) }
                }
        } label: { Text("Rename…") }
        Button(role: .destructive) { confirmDelete(lut) } label: { Text("Delete…") }
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
            () -> (presets: [String: CGImage], luts: [String: CGImage]) in
            var presetOut: [String: CGImage] = [:]
            var lutOut: [String: CGImage] = [:]
            // ONE decode for the whole grid; geometry is applied to the base so
            // every cell shows the crop the user is actually working in.
            guard let base = EditRenderer.decodedProxy(url: url, stack: draft, maxPixel: edge)
            else { return (presetOut, lutOut) }
            var geometryOnly = EditStack.fresh()
            if let geo = draft.geometryParams, !geo.isNeutral {
                geometryOnly.setGeometry { $0 = geo }
            }
            let cropped = EditRenderer.apply(geometryOnly, to: base.image,
                                             sourceLongEdge: base.longEdge)
            let longEdge = max(cropped.ciImage.extent.width, cropped.ciImage.extent.height)
            let context = RenderContexts.preview

            func render(_ stack: EditStack) -> CGImage? {
                let out = EditRenderer.apply(stack, to: cropped, sourceLongEdge: longEdge)
                let extent = out.ciImage.extent
                guard extent.width >= 1, extent.height >= 1, extent.width.isFinite else { return nil }
                return context.createCGImage(out.ciImage, from: extent, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }

            for preset in presets {
                if Task.isCancelled { return (presetOut, lutOut) }
                guard let stack = EditStackCodec.decode(preset.stack) else { continue }
                let candidate = EditTransfer.apply(groups: EditTransfer.adjustedGroups(of: stack),
                                                   from: stack, onto: .fresh())
                if let cg = render(candidate) { presetOut[preset.id] = cg }
            }
            for lut in luts {
                if Task.isCancelled { return (presetOut, lutOut) }
                var candidate = EditStack.fresh()
                candidate.setLut(LutParams(lutHash: lut.id, name: lut.name, strength: 1))
                if let cg = render(candidate) { lutOut[lut.id] = cg }
            }
            return (presetOut, lutOut)
        }.value

        // Latest wins: a sweep that started before the draft changed must not
        // paint stale thumbs over the newer one's.
        guard generation == sweepGeneration else { return }
        presetThumbs = rendered.presets
        lutThumbs = rendered.luts
    }
}
