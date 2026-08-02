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
    @Published var preset: SocialPreset = SocialPreset.all[0]
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
        self.includeEXIF = AppSettings.socialExifChoices[SocialPreset.all[0].id] ?? false
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

    /// The current photo's output dimensions — POST-crop, via
    /// `EffectiveDimensions`, so a cropped photo's size fields show the size
    /// it actually exports at rather than the sensor's.
    @Published private(set) var naturalSize: CGSize?

    /// Whether the current photo carries an alpha channel at all.
    ///
    /// The Background control is shown ONLY when this is true. An ordinary
    /// photograph has no transparency to place, so offering White / Black /
    /// Transparent for one is a control that does nothing — which is exactly
    /// how it read on review.
    @Published private(set) var sourceHasAlpha = false

    /// The card's decoded preview, handed up by the stage. Reused for the size
    /// estimate rather than decoding a second time.
    @Published var previewImage: CGImage?
    /// Result of the last estimate run. Nil while it's in flight or if the
    /// trial encode failed — better no number than a wrong one.
    @Published var estimatedBytes: Int?

    /// A header read on a cache miss, so never from a view body.
    func loadNaturalSize() async {
        guard let url = currentURL else { naturalSize = nil; sourceHasAlpha = false; return }
        let facts = await Task.detached(priority: .userInitiated) { () -> (CGSize?, Bool) in
            let size = EffectiveDimensions.cached(url) ?? EffectiveDimensions.resolve(url)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
            else { return (size, false) }
            return (size, (props[kCGImagePropertyHasAlpha as String] as? Bool) ?? false)
        }.value
        guard url == currentURL else { return }   // pager moved while we read
        naturalSize = facts.0
        sourceHasAlpha = facts.1
    }

    /// Re-measures the output size for the current settings. Cheap enough to
    /// run on every control change because it encodes the ≤2048px PREVIEW, not
    /// the full image, and scales the result.
    func refreshEstimate(outputPixelCount: Double) async {
        guard !isSocial, let url = currentURL, let preview = previewImage else {
            estimatedBytes = nil
            return
        }
        // DEBOUNCE FIRST, and it is load-bearing. This runs from `.task(id:)`
        // keyed on the settings, and dragging the quality slider changes them
        // on every frame. `.task(id:)` cancels the previous run — but a
        // `Task.detached` is detached from that cancellation by definition, so
        // without the sleep a single drag queued dozens of 2048px encodes that
        // all ran to completion. Sleeping first means the cancellation lands
        // here, before any work starts.
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }

        // The live toggles, not the stale copies inside `settings` — the same
        // merge `export(to:)` does, so the estimate measures what will be
        // written.
        var settings = self.settings
        settings.includeEXIF = includeEXIF
        settings.includeLocation = includeLocation
        let bytes = await Task.detached(priority: .utility) {
            ImageExportRender.estimatedBytes(preview: preview, settings: settings,
                                             for: url, outputPixelCount: outputPixelCount)
        }.value
        guard !Task.isCancelled, url == currentURL else { return }
        estimatedBytes = bytes
    }

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
            // Closing the card used to leave this loop running: files kept
            // landing in the folder with no UI attached to them. The card
            // cancels its task on disappear and the check lands here, between
            // files, so a partially-written one is never abandoned.
            if Task.isCancelled { break }
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

    /// The size fields are text, not Int bindings: a partially-typed number
    /// ("20" on the way to "2048") has to be a legal intermediate state, and an
    /// Int-formatted TextField fights the user for the cursor while they type.
    /// `commitWidth`/`commitHeight`/`commitPercent` are what the renderer sees.
    @State private var outWidth = ""
    @State private var outHeight = ""
    @State private var outPercent = "100"
    @State private var lockAspect = true
    /// Which size field has the caret. Used to commit on focus LOSS — a
    /// numeric field that only reads what you typed when you press Return
    /// silently discards it when you click Export instead.
    @FocusState private var focusedSizeField: SizeField?
    /// The running export, so closing the card can stop it.
    @State private var exportTask: Task<Void, Never>?

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

            HStack(alignment: .top, spacing: 20) {
                stage.frame(maxWidth: .infinity)
                Divider()
                controls.frame(width: 248)
            }
            .frame(height: 460)
        }
        .padding(28)
        // The photo's own dimensions drive the size fields, and a header read
        // is I/O — so it happens here, off the view body, and again whenever
        // the pager moves.
        .task(id: model.currentURL) { await model.loadNaturalSize(); resetSizeFields() }
        .onDisappear { exportTask?.cancel() }
        .onChange(of: focusedSizeField) { previous, _ in
            switch previous {
            case .width: commitWidth()
            case .height: commitHeight()
            case .percent: commitPercent()
            case nil: break
            }
        }
        // Re-measure on any change that moves the output: the settings, the
        // photo, or the preview finishing its decode.
        .task(id: estimateKey) {
            await model.refreshEstimate(
                outputPixelCount: outputPixelSize.map { Double($0.width * $0.height) } ?? 0)
        }
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
                                   set: { model.setState($0, for: url) }),
                    onDecoded: { model.previewImage = $0 })
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
        HStack(spacing: 4) {
            pagerButton("chevron.left", label: String(localized: "Previous image"),
                        disabled: model.pageIndex == 0) {
                model.pageIndex = max(0, model.pageIndex - 1)
            }
            Text("\(model.pageIndex + 1) of \(model.urls.count)")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 56)
            pagerButton("chevron.right", label: String(localized: "Next image"),
                        disabled: model.pageIndex >= model.urls.count - 1) {
                model.pageIndex = min(model.urls.count - 1, model.pageIndex + 1)
            }
        }
    }

    /// A bare SF Symbol inside a `.plain` button is only clickable on the
    /// glyph's own ink, which for a chevron is a few points of diagonal stroke.
    /// The 32pt square and the `contentShape` are what make it a target.
    private func pagerButton(_ symbol: String, label: String, disabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
        .accessibilityLabel(Text(label))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            presetPicker
            Divider()
            if model.isSocial {
                socialControls
            } else {
                formatControls
            }
            Spacer(minLength: 8)
            footer
        }
    }

    /// Everything the estimate depends on, so `.task(id:)` reruns when any of
    /// it moves and not otherwise.
    private var estimateKey: String {
        let px = outputPixelSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
        return [model.currentURL?.path ?? "-", px,
                model.settings.format.rawValue,
                String(model.settings.quality),
                String(model.settings.tiff16), String(model.settings.webpLossless),
                model.settings.background.rawValue,
                String(model.includeEXIF), String(model.includeLocation),
                model.previewImage == nil ? "0" : "1",
                model.isSocial ? "s" : "f"].joined(separator: "|")
    }

    /// The one number worth stating outright.
    ///
    /// It sits WITH the controls, not down by the buttons where it was: the
    /// thing it responds to is the quality slider two rows up, and a readout
    /// you have to hunt for at the far end of the card isn't feedback. It also
    /// no longer repeats the format or the dimensions — the preset dropdown
    /// and the size fields already say both, and a card that says everything
    /// twice reads as noise.
    private var estimatedSizeRow: some View {
        HStack {
            Text("Est. file size")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(estimatedSizeText)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
        }
        .animation(.easeOut(duration: 0.15), value: model.estimatedBytes)
        .accessibilityElement(children: .combine)
    }

    /// "≈" is load-bearing: the number comes from encoding the PREVIEW at these
    /// exact settings and scaling by pixel count — a real measurement, but of a
    /// smaller image, so it is close rather than exact.
    private var estimatedSizeText: String {
        guard let bytes = model.estimatedBytes else { return "—" }
        return "≈" + Self.byteFormatter.string(fromByteCount: Int64(bytes))
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB]
        return f
    }()

    /// The pixel size the current settings actually produce.
    private var outputPixelSize: CGSize? {
        guard let natural = model.naturalSize else { return nil }
        guard !model.isSocial else {
            return model.preset.isFixed
                ? model.preset.targetAspect.map { _ in
                    if case .fixed(let w, let h) = model.preset.kind {
                        return SocialRender.fixedFrame(width: w, height: h, decodedSize: natural)
                    }
                    return natural
                }
                : nil            // long-edge social sizes are the renderer's call
        }
        return model.settings.resize.targetSize(for: natural)
    }

    private var socialControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            socialOutputRow
            if model.preset.isFixed { fitModePicker }
            if let warning = model.preset.warningKey {
                Text(String(localized: String.LocalizationValue(warning)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            exifToggle
        }
    }

    /// What the platform preset actually produces. The format side has had
    /// editable size fields since the rebuild; the social side had NOTHING —
    /// you picked "Instagram" and found out the dimensions by opening the
    /// exported file. These aren't editable (the platform picks them, that's
    /// the point of a platform preset) but they have to be visible.
    private var socialOutputRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Size").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(socialSizeText)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            if let cropped = socialCropText {
                Text(cropped)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var socialSizeText: String {
        guard let natural = model.naturalSize else { return "—" }
        switch model.preset.kind {
        case .fixed(let w, let h):
            let frame = SocialRender.fixedFrame(width: w, height: h, decodedSize: natural)
            return "\(Int(frame.width)) × \(Int(frame.height)) px"
        case .longEdge(let cap):
            let t = ExportResize.longEdge(cap).targetSize(for: natural)
            return "\(Int(t.width)) × \(Int(t.height)) px"
        case .original:
            return "\(Int(natural.width)) × \(Int(natural.height)) px"
        }
    }

    /// How much of the picture the platform's fixed frame throws away, as a
    /// percentage of area. Only ever shown for a fixed preset in crop mode —
    /// Matte and Blur keep the whole image by construction, and a long-edge
    /// preset never crops at all.
    private var socialCropText: String? {
        guard model.preset.isFixed, model.fit == .crop,
              let natural = model.naturalSize,
              case .fixed(let w, let h) = model.preset.kind,
              natural.width > 0, natural.height > 0
        else { return nil }
        let frame = SocialRender.fixedFrame(width: w, height: h, decodedSize: natural)
        let lost = Int((SocialCropMath.croppedAwayFraction(
            sourceAspect: natural.width / natural.height,
            targetAspect: frame.width / frame.height) * 100).rounded())
        guard lost >= 1 else { return nil }
        return String(format: NSLocalizedString(
            "Crops about %lld%% of the picture — drag it to choose which part.",
            comment: "Export: how much a fixed social frame trims"), lost)
    }

    // MARK: - Format branch

    private var formatControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.resolvedFormat.supportsQuality { qualityControl }
            if model.resolvedFormat.supportsBitDepth {
                labelled(String(localized: "Bit depth")) {
                    Picker("", selection: $model.settings.tiff16) {
                        Text("8-bit").tag(false)
                        Text("16-bit").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .accessibilityLabel(Text("Bit depth"))
                }
            }
            if model.resolvedFormat == .webp {
                Toggle("Lossless", isOn: $model.settings.webpLossless)
                    .font(.system(size: 12))
                    .help("Reproduces every pixel exactly. Larger files, and worth it for graphics rather than photographs.")
            }
            sizeControl
            // Only when there IS transparency to place. An opaque photograph
            // has none, and offering the choice for one is a control that
            // does nothing.
            if model.sourceHasAlpha { backgroundControl }
            estimatedSizeRow
            Divider()
            exifToggle
            savePresetRow
        }
    }

    /// A section label over its control. Every group in this column uses it, so
    /// the label baseline and gap can't drift between them.
    private func labelled<Content: View>(_ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// The slider now says what it's set to. A slider with no readout is a
    /// control you can only aim, not set — you can't come back tomorrow and
    /// reproduce yesterday's export.
    private var qualityControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Quality")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(qualityPercent)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            Slider(value: $model.settings.quality, in: 0.3...1.0)
                .controlSize(.small)
                .accessibilityLabel(Text("Quality"))
                .accessibilityValue(Text(qualityPercent))
            Picker("", selection: qualityTierBinding) {
                ForEach(QualityTier.allCases, id: \.self) { tier in
                    Text(tier.displayName).tag(Optional(tier))
                }
                // Reached by dragging the slider off a tier, never by picking
                // — selecting it is a no-op rather than a jump to some
                // arbitrary value.
                Text("Custom").tag(Optional<QualityTier>.none)
            }
            .pickerStyle(.menu).labelsHidden()
            .accessibilityLabel(Text("Quality preset"))
        }
    }

    /// The tiers SET the slider; the slider reports which tier it's on, or
    /// Custom when it's between them.
    private var qualityTierBinding: Binding<QualityTier?> {
        Binding(get: { QualityTier.matching(model.settings.quality) },
                set: { if let tier = $0 { model.settings.quality = tier.value } })
    }

    /// Interpolated, so it needs an explicit format string rather than a
    /// literal the compiler could extract on its own.
    private var qualityPercent: String {
        String(format: NSLocalizedString("%lld%%", comment: "Export quality, as a percentage"),
               Int((model.settings.quality * 100).rounded()))
    }

    // MARK: - Size

    /// Width, height, and a percentage — all three live, all three the same
    /// number seen three ways.
    ///
    /// The dropdown this replaces made you choose a MODE (long edge / fit
    /// within) before you could type anything, which is a question about the
    /// implementation rather than about the picture. Two fields and a percent
    /// is what every other image app does, and it means the never-upscale rule
    /// needs no explaining: the fields simply won't go above the original, so
    /// the advisory line that used to sit above the buttons is gone.
    private var sizeControl: some View {
        labelled(String(localized: "Size")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    numberField($outWidth, label: String(localized: "Width"),
                                field: .width) { commitWidth() }
                    Text("×").font(.system(size: 11)).foregroundStyle(.secondary)
                    numberField($outHeight, label: String(localized: "Height"),
                                field: .height) { commitHeight() }
                    Text("px").font(.system(size: 11)).foregroundStyle(.secondary)
                    lockButton
                }
                HStack(spacing: 6) {
                    numberField($outPercent, label: String(localized: "Scale"),
                                field: .percent) { commitPercent() }
                    Text("%").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private var lockButton: some View {
        Button {
            lockAspect.toggle()
            if lockAspect { commitWidth() }
        } label: {
            Image(systemName: lockAspect ? "link" : "link.badge.plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(lockAspect ? Color.accentColor : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(lockAspect ? String(localized: "Aspect ratio locked")
                         : String(localized: "Aspect ratio unlocked"))
        .accessibilityLabel(Text("Lock aspect ratio"))
        .accessibilityValue(Text(lockAspect ? String(localized: "On") : String(localized: "Off")))
    }

    private enum SizeField: Hashable { case width, height, percent }

    private func numberField(_ value: Binding<String>, label: String,
                             field: SizeField,
                             commit: @escaping () -> Void) -> some View {
        TextField("", text: value)
            .focused($focusedSizeField, equals: field)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(width: 62)
            .onSubmit(commit)
            // Arrow keys nudge the number, Shift by ten. A numeric field you
            // can only retype is a numeric field you can't dial in — and
            // dialling in is the whole job once the size estimate is on screen.
            // `keys:` rather than the single-key overload — that one hands the
            // action no argument, and the modifiers are the point here.
            // `.repeat` is included so holding the key keeps stepping.
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                let magnitude = press.modifiers.contains(.shift) ? 10 : 1
                let sign = press.key == .upArrow ? 1 : -1
                return step(value, by: magnitude * sign, commit: commit)
            }
            .accessibilityLabel(Text(label))
    }

    private func step(_ value: Binding<String>, by delta: Int,
                      commit: () -> Void) -> KeyPress.Result {
        let current = Int(value.wrappedValue.filter(\.isNumber)) ?? 0
        value.wrappedValue = String(max(1, current + delta))
        commit()
        return .handled
    }

    /// Reads the fields back into `settings.resize`. Clamped to the natural
    /// size in both directions, which is where never-upscale actually lives now
    /// — the renderer still refuses to enlarge, but the UI never asks it to.
    private func commitWidth() {
        guard let natural = model.naturalSize, natural.width > 0 else { return }
        let w = min(Int(natural.width), clampPixels(outWidth))
        let h = lockAspect
            ? max(1, Int((CGFloat(w) * natural.height / natural.width).rounded()))
            : min(Int(natural.height), clampPixels(outHeight))
        applyOutput(width: w, height: h, natural: natural)
    }

    private func commitHeight() {
        guard let natural = model.naturalSize, natural.height > 0 else { return }
        let h = min(Int(natural.height), clampPixels(outHeight))
        let w = lockAspect
            ? max(1, Int((CGFloat(h) * natural.width / natural.height).rounded()))
            : min(Int(natural.width), clampPixels(outWidth))
        applyOutput(width: w, height: h, natural: natural)
    }

    private func commitPercent() {
        guard let natural = model.naturalSize else { return }
        let pct = min(100, max(1, Int(outPercent.filter(\.isNumber)) ?? 100))
        applyOutput(width: max(1, Int((natural.width * CGFloat(pct) / 100).rounded())),
                    height: max(1, Int((natural.height * CGFloat(pct) / 100).rounded())),
                    natural: natural)
    }

    /// One place where the three fields and `settings.resize` are reconciled,
    /// so they can't disagree about what the output is.
    private func applyOutput(width: Int, height: Int, natural: CGSize) {
        showOutput(width: width, height: height, natural: natural)
        model.settings.resize =
            (width >= Int(natural.width) && height >= Int(natural.height))
            ? .original
            : .fitWithin(width: width, height: height)
    }

    /// Fields ONLY. Kept separate from `applyOutput` because showing what the
    /// current setting means for THIS photo must never be mistaken for the user
    /// changing that setting — `resetSizeFields` used to write back through
    /// `applyOutput`, so paging to a photo of a different aspect re-derived the
    /// box against it and stored the smaller result. The setting ratcheted down
    /// every time you moved between photos.
    private func showOutput(width: Int, height: Int, natural: CGSize) {
        outWidth = String(width)
        outHeight = String(height)
        let pct = natural.width > 0 ? (CGFloat(width) / natural.width * 100).rounded() : 100
        outPercent = String(Int(max(1, min(100, pct))))
    }

    /// Fills the fields from the photo's own dimensions. Runs when the card
    /// opens and whenever the pager moves to a different photo.
    private func resetSizeFields() {
        guard let natural = model.naturalSize else { return }
        switch model.settings.resize {
        case .original:
            outWidth = String(Int(natural.width))
            outHeight = String(Int(natural.height))
            outPercent = "100"
        case .longEdge(let cap):
            let t = ExportResize.longEdge(cap).targetSize(for: natural)
            showOutput(width: Int(t.width), height: Int(t.height), natural: natural)
        case .fitWithin(let w, let h):
            let t = ExportResize.fitWithin(width: w, height: h).targetSize(for: natural)
            showOutput(width: Int(t.width), height: Int(t.height), natural: natural)
        }
    }

    /// Everything typed but not yet committed. Called before an export runs,
    /// because a value only committed `onSubmit` is a value you can type, click
    /// Export, and never get — the field showed 800 and the file came out 4000.
    private func commitPendingSizeEdits() {
        switch focusedSizeField {
        case .width: commitWidth()
        case .height: commitHeight()
        case .percent: commitPercent()
        case nil: break
        }
    }

    /// A pasted nonsense number must never reach the renderer. 100 000 is well
    /// past any real sensor and still far under the decode budget.
    private func clampPixels(_ text: String) -> Int {
        min(100_000, max(1, Int(text.filter(\.isNumber)) ?? 1))
    }

    // MARK: - Background

    /// What a transparent pixel becomes. Always visible, including for JPEG —
    /// the question "what happens to my transparency" is exactly the one that
    /// had no answer on the card before, and hiding the control for the formats
    /// that can't keep it is what made it unanswerable.
    private var backgroundControl: some View {
        labelled(String(localized: "Background")) {
            VStack(alignment: .leading, spacing: 4) {
                Picker("", selection: $model.settings.background) {
                    ForEach(backgroundOptions, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityLabel(Text("Background"))
                if model.settings.background == .transparent,
                   model.resolvedFormat.canCarryAlpha == false {
                    Text("JPEG has no transparency — this exports on white.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Transparent is only OFFERED where the container can carry it, but the
    /// stored choice is left alone when you switch to a format that can't —
    /// switching JPEG → PNG → JPEG must not silently forget that you wanted
    /// transparency.
    private var backgroundOptions: [ExportBackground] {
        model.resolvedFormat.canCarryAlpha
            ? ExportBackground.allCases
            : [.white, .black]
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

    // MARK: - Preset dropdown

    /// Comparable tags for a menu that mixes three kinds of entry.
    private enum PickerTag: Hashable {
        case format(ExportFormat)
        case social(String)
        case saved(UUID)
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Preset").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                // Only for one you MADE. There is no deleting JPEG or Instagram,
                // and a trash can that's disabled most of the time is worse
                // than one that appears when it applies.
                if let saved = activeSavedPreset { deletePresetButton(saved) }
            }
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

    private func deletePresetButton(_ saved: SavedExportPreset) -> some View {
        Button {
            // Confirmed, and raised through the SHELL's alert — the same path
            // the editor's "Delete this LUT?" takes, which is presented on the
            // outer stack and so draws above this card rather than behind it.
            appState.alertRequest = MuseAlert.confirm(
                title: String(localized: "Delete this preset?"),
                message: String(localized: "The files you've already exported are unaffected."),
                confirmTitle: String(localized: "Delete"),
                onConfirm: { ExportPresetStore.shared.delete(id: saved.id) })
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Delete this preset")
        .accessibilityLabel(Text("Delete this preset"))
    }

    /// The saved preset whose settings are EXACTLY what's on screen, if any.
    /// Derived rather than remembered: pick a preset and it shows as selected;
    /// nudge any control and it falls back to the plain format by itself, the
    /// same way the quality tiers fall back to Custom. Nothing to invalidate,
    /// so nothing can go stale.
    private var activeSavedPreset: SavedExportPreset? {
        guard !model.isSocial else { return nil }
        var current = model.settings
        current.includeEXIF = model.includeEXIF
        current.includeLocation = model.includeLocation
        return presetStore.presets.first { $0.settings == current }
    }

    private var pickerBinding: Binding<PickerTag> {
        Binding(
            get: {
                switch model.selection {
                case .format(let f):
                    return activeSavedPreset.map { .saved($0.id) } ?? .format(f)
                case .social(let p):
                    return .social(p.id)
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
                        resetSizeFields()
                    }
                }
            })
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
                    exportTask = Task { await runExport() }
                }
                .disabled(model.urls.isEmpty)
            }
        }
    }

    private func runExport() async {
        // Belt and braces over the focus-loss commit: SwiftUI does not promise
        // that focus leaves the field before a button's action runs.
        commitPendingSizeEdits()
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
    /// Handed up so the size estimate can encode THIS image rather than
    /// decoding the file a second time.
    var onDecoded: ((CGImage) -> Void)?

    /// `nonisolated`: read by the card's off-main preview decode.
    nonisolated static let previewMaxPixel = 2048

    @State private var image: NSImage?
    @State private var loadedURL: URL?

    var body: some View {
        GeometryReader { geo in
            let frame = frameRect(in: geo.size)
            ZStack {
                // No backing plate. It used to fill the whole stage area with a
                // grey wash, which on any photo that didn't match the stage's
                // aspect read as two arbitrary bands above and below the
                // picture. The picture sits on the card's own surface now, and
                // the only thing drawn around it is its own hairline.
                content(in: frame)
                    .frame(width: frame.width, height: frame.height)
                    .clipped()
                    .overlay(safeZones(in: frame))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
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
        let decoded = await Task.detached(priority: .userInitiated) { () -> (NSImage, CGSize, CGImage)? in
            guard let src = CGImageSourceCreateWithURL(target as CFURL, nil),
                  ThumbnailCache.withinDecodeBudget(src) else { return nil }
            if let stack,
               let rendered = EditRenderer.render(url: target, stack: stack,
                                                  maxPixel: Self.previewMaxPixel) {
                let size = CGSize(width: rendered.width, height: rendered.height)
                return (NSImage(cgImage: rendered, size: size), size, rendered)
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.previewMaxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
            let size = CGSize(width: cg.width, height: cg.height)
            return (NSImage(cgImage: cg, size: size), size, cg)
        }.value
        guard let decoded, target == url else { return }
        onDecoded?(decoded.2)
        image = decoded.0
        var s = state
        s.decodedSize = decoded.1
        state = s
        loadedURL = target
    }
}
