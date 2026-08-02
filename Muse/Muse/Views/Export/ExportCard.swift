//
//  ExportCard.swift
//  Muse
//
//  The export card. ONE card with two preset families, because they're the same
//  act: pick what comes out, then press Export. The dropdown's Format section
//  produces a normal image file (this is the only way to get a JPEG out of a
//  RAW); its Social section is Spec 07's twelve platform presets, unchanged; My
//  Presets is whatever the user has named and kept.
//
//  The controls column swaps on the branch — quality/depth/size for a format,
//  crop/matte/advisory for a platform — and everything else (stage, pager,
//  footer, progress, folder picker, collected per-file failures) is shared.
//
//  Nothing here persists unless the user explicitly saves a version or a preset
//  — crop positions, zooms, fit modes and the location toggle all die with the
//  card. The remembered bits are the per-preset EXIF choice, the matte shade,
//  and the last format settings, so the card reopens where you left it.
//

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A per-run social export request. Raised from the grid context menu, the hero
/// viewer's share menu, or the collection header — none of which can present an
/// in-window card themselves (it would be sized against the control).
struct ExportRequest: Identifiable, Equatable {
    let id = UUID()
    var urls: [URL]           // raster kinds only, in grid order
}

@MainActor final class ExportModel: ObservableObject {
    struct PerImageState: Equatable {
        var zoom: CGFloat = 1
        var center = CGPoint(x: 0.5, y: 0.5)
        /// The decoded preview's pixel size. The crop rect is normalized in THIS
        /// space (that's the space the user positions it in), so the render job
        /// must be handed a rect derived from it — not from the raw file.
        var decodedSize: CGSize?
    }

    /// What the dropdown is on. A format and a social platform are different
    /// enough — one has a crop stage and a fixed size, the other a quality
    /// slider and a free one — that the card branches on this rather than
    /// pretending they're one kind of preset.
    enum Selection: Equatable {
        case format(ExportFormat)
        case social(SocialPreset)
    }

    @Published var urls: [URL]
    @Published var pageIndex = 0
    /// The FORMAT branch's choices. Loaded from the last export so the card
    /// reopens where you left it.
    @Published var settings: ExportSettings
    @Published var selection: Selection
    /// The social branch's platform. Kept as its own property, not derived from
    /// `selection`, so the crop stage and `willNotUpscale` keep working
    /// untouched — they were written against a non-optional preset.
    @Published var preset: SocialPreset = SocialPreset.preset(id: "ig-feed-portrait") ?? SocialPreset.all[0]
    @Published var fit: SocialFit = .crop
    @Published var matte: MatteShade
    @Published var includeEXIF: Bool
    @Published var includeLocation = false   // never remembered — always reverts to OFF
    @Published var perImage: [URL: PerImageState] = [:]
    @Published var isExporting = false
    @Published var exportProgress: (Int, Int) = (0, 0)
    @Published var failures: [String] = []
    /// Non-nil while the inline "name this preset" row is showing. Inline
    /// rather than a nested sheet: this card is already a modal, and a modal
    /// over a modal is where keyboard focus goes wrong.
    @Published var pendingPresetName: String?

    init(urls: [URL]) {
        self.urls = urls
        self.matte = MatteShade(rawValue: AppSettings.socialMatteShade) ?? .white
        self.includeEXIF = AppSettings.socialExifChoices["ig-feed-portrait"] ?? false
        let restored = AppSettings.lastExportSettings
            .flatMap { try? JSONDecoder().decode(ExportSettings.self, from: $0) }
            ?? ExportSettings()
        // A restored format the machine can no longer write (a build without
        // the WebP encoder, say) falls back rather than offering a dead entry.
        var resolved = restored
        if !ExportFormat.available.contains(resolved.format) { resolved.format = .jpeg }
        self.settings = resolved
        self.selection = .format(resolved.format)
        self.includeEXIF = resolved.includeEXIF
        self.includeLocation = resolved.includeLocation
    }

    var currentURL: URL? { urls.indices.contains(pageIndex) ? urls[pageIndex] : nil }

    var isSocial: Bool { if case .social = selection { true } else { false } }

    /// The concrete format the current file will be written in — what the
    /// quality and bit-depth controls key off, since `.sameAsOriginal` is a
    /// per-file answer.
    var resolvedFormat: ExportFormat {
        guard let url = currentURL else { return settings.format }
        return settings.format.resolved(for: url)
    }

    func selectFormat(_ f: ExportFormat) {
        settings.format = f
        selection = .format(f)
    }

    /// Loading a saved preset replaces the whole settings object — a preset is
    /// a complete answer, not a patch. Its EXIF choices come with it.
    func apply(_ saved: SavedExportPreset) {
        settings = saved.settings
        includeEXIF = saved.settings.includeEXIF
        includeLocation = saved.settings.includeLocation
        selection = .format(saved.settings.format)
    }

    func state(for url: URL) -> PerImageState { perImage[url] ?? PerImageState() }
    func setState(_ s: PerImageState, for url: URL) { perImage[url] = s }

    func selectPreset(_ p: SocialPreset) {
        preset = p
        selection = .social(p)
        includeEXIF = AppSettings.socialExifChoices[p.id] ?? p.exifDefaultOn
        includeLocation = false
        // The fit control only exists for fixed-dimension presets.
        if p.isFixed == false { fit = .crop }
    }

    /// True when the source can't fill what was asked for — the card says so
    /// rather than silently exporting something smaller. Never-upscale is a
    /// global rule, so this covers the format branch's resize modes too.
    var willNotUpscale: Bool {
        guard let url = currentURL, let size = state(for: url).decodedSize else { return false }
        guard isSocial else {
            return settings.resize != .original
                && settings.resize.targetSize(for: size) == size
        }
        switch preset.kind {
        case .fixed(let w, let h):
            return SocialRender.fixedFrame(width: w, height: h, decodedSize: size)
                != CGSize(width: CGFloat(w), height: CGFloat(h))
        case .longEdge(let cap):
            return max(size.width, size.height) < CGFloat(cap)
        case .original:
            return false
        }
    }

    private func rememberChoices() {
        if isSocial {
            var choices = AppSettings.socialExifChoices
            choices[preset.id] = includeEXIF
            AppSettings.socialExifChoices = choices
            if fit == .matte || fit == .blurExtend { AppSettings.socialMatteShade = matte.rawValue }
        } else {
            var s = settings
            s.includeEXIF = includeEXIF
            s.includeLocation = includeLocation
            AppSettings.lastExportSettings = try? JSONEncoder().encode(s)
        }
    }

    /// Name the current format settings and keep them. Offered only on the
    /// format branch — a social platform is already a preset, and a saved copy
    /// of one would be a second name for the same fixed numbers that couldn't
    /// track a change to the platform table.
    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSocial else { return }
        var s = settings
        s.includeEXIF = includeEXIF
        s.includeLocation = includeLocation
        ExportPresetStore.shared.save(name: trimmed, settings: s)
    }

    /// Runs sequentially off-main. Per-file failures collect into `failures`
    /// rather than aborting the run — one undecodable file shouldn't cost the
    /// user the other nine.
    func export(to directory: URL) async {
        isExporting = true
        failures = []
        exportProgress = (0, urls.count)
        let preset = self.preset, fit = self.fit, matte = self.matte
        let includeEXIF = self.includeEXIF, includeLocation = self.includeLocation
        let social = isSocial
        var formatSettings = settings
        formatSettings.includeEXIF = includeEXIF
        formatSettings.includeLocation = includeLocation
        for (i, url) in urls.enumerated() {
            let s = state(for: url)
            do {
                if social {
                    // A crop rect is only meaningful for a fixed preset in crop
                    // mode; everything else lets the renderer derive its own.
                    let cropRect: CGRect? = (fit == .crop && preset.isFixed)
                        ? SocialCropMath.rect(sourceSize: s.decodedSize ?? .zero,
                                              targetAspect: preset.targetAspect ?? 1,
                                              zoom: s.zoom, center: s.center)
                        : nil
                    let job = SocialRender.Job(sourceURL: url, preset: preset, fit: fit,
                                               matte: matte, cropRect: cropRect,
                                               includeEXIF: includeEXIF,
                                               includeLocation: includeLocation)
                    _ = try await Task.detached(priority: .userInitiated) {
                        try SocialRender.export(job, to: directory)
                    }.value
                } else {
                    let job = ImageExportRender.Job(sourceURL: url, settings: formatSettings)
                    _ = try await Task.detached(priority: .userInitiated) {
                        try ImageExportRender.export(job, to: directory)
                    }.value
                }
            } catch {
                failures.append(url.lastPathComponent)
            }
            exportProgress = (i + 1, urls.count)
        }
        isExporting = false
        rememberChoices()
    }

    /// "Save Crop as Version": compose the social rect into the photo's existing
    /// geometry and write ONE `edit_versions` row. The current stack is
    /// untouched — this is the single opt-in that persists anything at all.
    func saveCropAsVersion(for url: URL) async {
        guard preset.isFixed, fit == .crop else { return }
        let s = state(for: url)
        let social = SocialCropMath.rect(sourceSize: s.decodedSize ?? .zero,
                                         targetAspect: preset.targetAspect ?? 1,
                                         zoom: s.zoom, center: s.center)
        var stack = await EditStore.shared.stack(for: url) ?? .fresh()
        let existing = stack.geometryParams?.crop.map { (c: CropRect) in
            CGRect(x: c.x, y: c.y, width: c.w, height: c.h)
        }
        let composed = SocialCropMath.composedCrop(existing: existing, social: social)
        stack.setGeometry { g in
            g.crop = CropRect(x: Double(composed.minX), y: Double(composed.minY),
                              w: Double(composed.width), h: Double(composed.height))
        }
        await EditStore.shared.saveVersion(
            name: String(localized: String.LocalizationValue(preset.nameKey)),
            kind: "version", stack: stack, for: url)
    }
}

/// Presents the card at the SHELL — a menu item can't present an in-window card
/// itself (it would be sized against the control). Its own modifier so the
/// detail view's modifier chain stays inside the type-checker's budget.
struct ExportModal: ViewModifier {
    @EnvironmentObject private var appState: AppState

    func body(content: Content) -> some View {
        content.museModal(isPresented: Binding(
            get: { appState.exportRequest != nil },
            set: { if !$0 { appState.exportRequest = nil } }),
                          width: 760,
                          palette: appState.moodPalette) {
            if let request = appState.exportRequest {
                ExportCard(request: request) {
                    appState.exportRequest = nil
                }
            }
        }
    }
}

struct ExportCard: View {
    @StateObject private var model: ExportModel
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var presetStore = ExportPresetStore.shared
    let onClose: () -> Void

    /// The resize fields are text, not Int bindings: a partially-typed number
    /// ("20" on the way to "2048") has to be a legal intermediate state, and an
    /// Int-formatted TextField fights the user for the cursor while they type.
    /// `clampPixels` is what turns the text into something the renderer sees.
    @State private var longEdge = "2048"
    @State private var fitWidth = "2000"
    @State private var fitHeight = "2000"

    init(request: ExportRequest, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: ExportModel(urls: request.urls))
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Export").font(.system(size: 24, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                SheetCloseButton { onClose() }
            }
            .padding(.bottom, 16)

            HStack(alignment: .top, spacing: 16) {
                stage.frame(maxWidth: .infinity)
                Divider()
                controls.frame(width: 240)
            }
            .frame(height: 460)
        }
        .padding(28)
    }

    private var stage: some View {
        VStack(spacing: 10) {
            if let url = model.currentURL {
                // `preset: nil` is the format branch — the same view, drawn
                // aspect-fit with no crop gesture and no safe zones. One
                // preview loader, not two.
                ExportStageView(
                    url: url,
                    preset: model.isSocial ? model.preset : nil,
                    fit: model.fit,
                    matte: model.matte,
                    state: Binding(get: { model.state(for: url) },
                                   set: { model.setState($0, for: url) }))
            } else {
                Text("Nothing to export.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.urls.count > 1 { pager }
            if model.isSocial, model.preset.isFixed, model.fit == .crop, let url = model.currentURL {
                // The ONE opt-in that persists anything: a separate version row,
                // never a change to the photo's current stack.
                ModalButton(title: String(localized: "Save Crop as Version")) {
                    Task { await model.saveCropAsVersion(for: url) }
                }
            }
        }
    }

    private var pager: some View {
        HStack(spacing: 12) {
            Button { model.pageIndex = max(0, model.pageIndex - 1) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(model.pageIndex == 0)
            .accessibilityLabel(Text("Previous image"))
            Text("\(model.pageIndex + 1) of \(model.urls.count)")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button { model.pageIndex = min(model.urls.count - 1, model.pageIndex + 1) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(model.pageIndex >= model.urls.count - 1)
            .accessibilityLabel(Text("Next image"))
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            presetPicker
            if model.isSocial {
                socialControls
            } else {
                formatControls
            }
            Spacer(minLength: 8)
            if let advisory {
                Text(advisory)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.willNotUpscale {
                Text("This photo is smaller than the size you asked for — it exports at its own size rather than being enlarged.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
    }

    private var socialControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.preset.isFixed { fitModePicker }
            if let warning = model.preset.warningKey {
                Text(String(localized: String.LocalizationValue(warning)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            exifToggle
        }
    }

    // MARK: - Format branch

    private var formatControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.resolvedFormat.supportsQuality {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality").font(.system(size: 12)).foregroundStyle(.secondary)
                    Slider(value: $model.settings.quality, in: 0.3...1.0)
                        .accessibilityLabel(Text("Quality"))
                        .accessibilityValue(Text(qualityPercent))
                }
            }
            if model.resolvedFormat.supportsBitDepth {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bit depth").font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("", selection: $model.settings.tiff16) {
                        Text("8-bit").tag(false)
                        Text("16-bit").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .accessibilityLabel(Text("Bit depth"))
                }
            }
            resizeControls
            exifToggle
            savePresetRow
        }
    }

    /// Interpolated, so it needs an explicit format string rather than a
    /// literal the compiler could extract on its own.
    private var qualityPercent: String {
        String(format: NSLocalizedString("%lld%%", comment: "Export quality, as a percentage"),
               Int((model.settings.quality * 100).rounded()))
    }

    private var resizeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Size").font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("", selection: resizeModeBinding) {
                Text("Original size").tag(ResizeMode.original)
                Text("Long edge").tag(ResizeMode.longEdge)
                Text("Fit within").tag(ResizeMode.fitWithin)
            }
            .pickerStyle(.menu).labelsHidden()
            .accessibilityLabel(Text("Size"))

            switch resizeModeBinding.wrappedValue {
            case .original:
                EmptyView()
            case .longEdge:
                pixelField(String(localized: "Pixels"), value: $longEdge) {
                    model.settings.resize = .longEdge(clampPixels(longEdge))
                }
            case .fitWithin:
                HStack(spacing: 8) {
                    pixelField(String(localized: "Width"), value: $fitWidth) {
                        model.settings.resize = .fitWithin(width: clampPixels(fitWidth),
                                                           height: clampPixels(fitHeight))
                    }
                    pixelField(String(localized: "Height"), value: $fitHeight) {
                        model.settings.resize = .fitWithin(width: clampPixels(fitWidth),
                                                           height: clampPixels(fitHeight))
                    }
                }
            }
        }
    }

    private func pixelField(_ label: String, value: Binding<String>,
                            commit: @escaping () -> Void) -> some View {
        TextField(label, text: value)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .onSubmit(commit)
            .onChange(of: value.wrappedValue) { _, _ in commit() }
            .accessibilityLabel(Text(label))
    }

    /// A pasted nonsense number must never reach the renderer. 100 000 is well
    /// past any real sensor and still far under the decode budget.
    private func clampPixels(_ text: String) -> Int {
        min(100_000, max(1, Int(text.filter(\.isNumber)) ?? 1))
    }

    private var savePresetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pending = model.pendingPresetName {
                // Inline, not a nested sheet: this card is already a modal, and
                // a modal over a modal is where keyboard focus goes wrong.
                TextField(String(localized: "Preset name"),
                          text: Binding(get: { pending },
                                        set: { model.pendingPresetName = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { commitPreset() }
                HStack(spacing: 8) {
                    ModalButton(title: String(localized: "Cancel")) {
                        model.pendingPresetName = nil
                    }
                    ModalButton(title: String(localized: "Save"), kind: .prominent) {
                        commitPreset()
                    }
                    .disabled(pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                ModalButton(title: String(localized: "Save Settings as Preset…")) {
                    model.pendingPresetName = ""
                }
            }
        }
    }

    private func commitPreset() {
        guard let name = model.pendingPresetName else { return }
        model.saveCurrentAsPreset(named: name)
        model.pendingPresetName = nil
    }

    /// The advisories that only the format branch raises. Each is ONE key —
    /// never `String(localized:) + name`, which ships the name's half in
    /// English and no remaining-English grep catches it.
    private var advisory: String? {
        guard !model.isSocial, let url = model.currentURL else { return nil }
        if model.settings.format == .sameAsOriginal, isRaw(url) {
            return String(localized: "RAW can’t be written back — this exports as JPEG.")
        }
        if model.settings.format == .tiff, model.settings.tiff16,
           EditStackIndex.stackHash(for: url) != nil {
            return String(localized: "This photo has edits, which render at 8-bit — 16-bit adds depth the data doesn’t have.")
        }
        return nil
    }

    /// A RAW is exactly a file whose container `.sameAsOriginal` can't keep.
    private func isRaw(_ url: URL) -> Bool {
        AssetKind.detect(at: url) == .raw
    }

    // MARK: - Preset dropdown

    /// Comparable tags for a menu that mixes three kinds of entry.
    private enum PickerTag: Hashable {
        case format(ExportFormat)
        case social(String)
        case saved(UUID)
    }

    private enum ResizeMode: Hashable { case original, longEdge, fitWithin }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preset").font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("", selection: pickerBinding) {
                Section("Format") {
                    ForEach(ExportFormat.available, id: \.self) { f in
                        Text(f.displayName).tag(PickerTag.format(f))
                    }
                }
                Section("Social") {
                    ForEach(SocialPreset.all) { p in
                        Text(String(localized: String.LocalizationValue(p.nameKey)))
                            .tag(PickerTag.social(p.id))
                    }
                }
                if !presetStore.presets.isEmpty {
                    Section("My Presets") {
                        ForEach(presetStore.presets) { p in
                            Text(p.name).tag(PickerTag.saved(p.id))
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel(Text("Preset"))
        }
    }

    private var pickerBinding: Binding<PickerTag> {
        Binding(
            get: {
                switch model.selection {
                case .format(let f): .format(f)
                case .social(let p): .social(p.id)
                }
            },
            set: { tag in
                switch tag {
                case .format(let f):
                    model.selectFormat(f)
                case .social(let id):
                    if let p = SocialPreset.preset(id: id) { model.selectPreset(p) }
                case .saved(let id):
                    if let saved = presetStore.presets.first(where: { $0.id == id }) {
                        model.apply(saved)
                        syncResizeFields()
                    }
                }
            })
    }

    private var resizeModeBinding: Binding<ResizeMode> {
        Binding(
            get: {
                switch model.settings.resize {
                case .original: .original
                case .longEdge: .longEdge
                case .fitWithin: .fitWithin
                }
            },
            set: { mode in
                switch mode {
                case .original: model.settings.resize = .original
                case .longEdge: model.settings.resize = .longEdge(clampPixels(longEdge))
                case .fitWithin: model.settings.resize = .fitWithin(width: clampPixels(fitWidth),
                                                                    height: clampPixels(fitHeight))
                }
            })
    }

    /// Loading a saved preset has to push its numbers back into the text
    /// fields, or the fields would keep showing the previous values while the
    /// settings underneath said something else.
    private func syncResizeFields() {
        switch model.settings.resize {
        case .original:
            break
        case .longEdge(let n):
            longEdge = String(n)
        case .fitWithin(let w, let h):
            fitWidth = String(w)
            fitHeight = String(h)
        }
    }

    private var fitModePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $model.fit) {
                Text("Crop").tag(SocialFit.crop)
                Text("Matte").tag(SocialFit.matte)
                Text("Blur").tag(SocialFit.blurExtend)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text("Fit"))
            if model.fit == .matte || model.fit == .blurExtend {
                HStack(spacing: 8) {
                    matteDot(.white)
                    matteDot(.black)
                }
            }
        }
    }

    private func matteDot(_ shade: MatteShade) -> some View {
        Button { model.matte = shade } label: {
            Circle()
                .fill(shade == .white ? Color.white : Color.black)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(model.matte == shade ? Color.accentColor : Color.secondary,
                                         lineWidth: model.matte == shade ? 2 : 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(shade == .white
                                 ? String(localized: "White border")
                                 : String(localized: "Black border")))
    }

    private var exifToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Include camera info (EXIF)", isOn: $model.includeEXIF)
            if model.includeEXIF {
                Toggle("Include location", isOn: $model.includeLocation)
                    .padding(.leading, 16)
                    .font(.system(size: 12))
            }
        }
    }

    private var footer: some View {
        HStack {
            ModalButton(title: String(localized: "Cancel")) { onClose() }
            Spacer()
            if model.isExporting {
                ProgressView(value: Double(model.exportProgress.0),
                             total: Double(max(1, model.exportProgress.1)))
                    .frame(width: 90)
            } else {
                ModalButton(title: String(localized: "Export…"), kind: .prominent, isDefault: true) {
                    Task { await runExport() }
                }
                .disabled(model.urls.isEmpty)
            }
        }
    }

    private func runExport() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export")
        panel.message = String(localized: "Choose where to save the exported images.")
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        await model.export(to: directory)
        if model.failures.isEmpty {
            onClose()
        } else {
            appState.alertRequest = .message(
                title: String(localized: "Some Exports Failed"),
                message: model.failures.joined(separator: ", "))
        }
    }
}

/// The crop/pan/zoom stage. Decodes the current image DIRECTLY at ≤ 2048 — no
/// `ThumbnailCache` entry, so no `renderedVariants` change (the compare-pane
/// rule: a one-off preview size must never enter the path-keyed cache).
/// The card's preview. `preset == nil` is the FORMAT branch: the same loader
/// and the same letterboxed frame, drawn aspect-fit with no crop gesture and no
/// safe zones. One preview implementation, not two — the decode below is the
/// fiddly part (it has to show EDITED pixels) and duplicating it would mean two
/// places to get that wrong.
struct ExportStageView: View {
    let url: URL
    let preset: SocialPreset?
    let fit: SocialFit
    let matte: MatteShade
    @Binding var state: ExportModel.PerImageState

    /// `nonisolated`: read by the card's off-main preview decode.
    nonisolated static let previewMaxPixel = 2048

    @State private var image: NSImage?
    @State private var loadedURL: URL?

    var body: some View {
        GeometryReader { geo in
            let frame = frameRect(in: geo.size)
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.06))
                content(in: frame)
                    .frame(width: frame.width, height: frame.height)
                    .clipped()
                    .overlay(safeZones(in: frame))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.secondary.opacity(0.5)))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(in: frame))
        }
        .task(id: url) { await load() }
        .accessibilityLabel(Text(preset == nil
                                 ? String(localized: "Preview")
                                 : String(localized: "Crop preview")))
    }

    @ViewBuilder
    private func content(in frame: CGSize) -> some View {
        if let image {
            if preset == nil {
                // Format branch: just the picture, at its own aspect.
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
            switch fit {
            case .crop:
                // Aspect-FILL the frame, then offset by the chosen center — the
                // same geometry SocialCropMath describes, drawn.
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(state.zoom)
                    .offset(x: (0.5 - state.center.x) * frame.width * state.zoom,
                            y: (0.5 - state.center.y) * frame.height * state.zoom)
            case .matte, .blurExtend:
                ZStack {
                    if fit == .blurExtend {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 24)
                    } else {
                        (matte == .white ? Color.white : Color.black)
                    }
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// Story/Reel presets draw the 250/1920-fraction top and bottom bands where
    /// platform chrome covers the picture.
    @ViewBuilder
    private func safeZones(in frame: CGSize) -> some View {
        if preset?.storySafeZones == true {
            let band = frame.height * (250.0 / 1920.0)
            VStack(spacing: 0) {
                Rectangle().fill(Color.black.opacity(0.28)).frame(height: band)
                Spacer(minLength: 0)
                Rectangle().fill(Color.black.opacity(0.28)).frame(height: band)
            }
            .allowsHitTesting(false)
        }
    }

    private func dragGesture(in frame: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard let preset, fit == .crop, preset.isFixed,
                      frame.width > 0, frame.height > 0 else { return }
                // Dragging moves the picture, so the crop center moves the other
                // way. Clamping lives in SocialCropMath — this only proposes.
                let dx = value.translation.width / frame.width / max(state.zoom, 0.001)
                let dy = value.translation.height / frame.height / max(state.zoom, 0.001)
                var s = state
                s.center = CGPoint(x: min(1, max(0, s.center.x - dx * 0.05)),
                                   y: min(1, max(0, s.center.y - dy * 0.05)))
                state = s
            }
    }

    /// The target frame, letterboxed inside the available stage area.
    private func frameRect(in available: CGSize) -> CGSize {
        let aspect: CGFloat
        if let a = preset?.targetAspect {
            aspect = a
        } else if let image, image.size.height > 0 {
            aspect = image.size.width / image.size.height
        } else {
            aspect = 1
        }
        let byWidth = CGSize(width: available.width, height: available.width / aspect)
        return byWidth.height <= available.height
            ? byWidth
            : CGSize(width: available.height * aspect, height: available.height)
    }

    private func load() async {
        guard loadedURL != url else { return }
        let target = url
        // The export ships EDITED pixels (SocialRender goes through
        // OutputRender), so the crop stage has to show them: previewing the
        // original meant the user positioned the crop against a picture that
        // wasn't what came out — and with a crop or straighten in the stack
        // the two didn't even share a frame, so `decodedSize` fed the crop
        // math the wrong geometry.
        let stack = EditStackIndex.resolvedStack(for: target)
        let decoded = await Task.detached(priority: .userInitiated) { () -> (NSImage, CGSize)? in
            guard let src = CGImageSourceCreateWithURL(target as CFURL, nil),
                  ThumbnailCache.withinDecodeBudget(src) else { return nil }
            if let stack,
               let rendered = EditRenderer.render(url: target, stack: stack,
                                                  maxPixel: Self.previewMaxPixel) {
                let size = CGSize(width: rendered.width, height: rendered.height)
                return (NSImage(cgImage: rendered, size: size), size)
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.previewMaxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
            let size = CGSize(width: cg.width, height: cg.height)
            return (NSImage(cgImage: cg, size: size), size)
        }.value
        guard let decoded, target == url else { return }
        image = decoded.0
        var s = state
        s.decodedSize = decoded.1
        state = s
        loadedURL = target
    }
}
