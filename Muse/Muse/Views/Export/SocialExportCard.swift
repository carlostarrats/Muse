//
//  SocialExportCard.swift
//  Muse
//
//  The social export card: pick a platform preset, position the crop, export.
//  Nothing here persists unless the user explicitly saves a version — crop
//  positions, zooms, fit modes and the location toggle all die with the card.
//  The only remembered bits are the per-preset EXIF choice and the matte shade.
//

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A per-run social export request. Raised from the grid context menu, the hero
/// viewer's share menu, or the collection header — none of which can present an
/// in-window card themselves (it would be sized against the control).
struct SocialExportRequest: Identifiable, Equatable {
    let id = UUID()
    var urls: [URL]           // raster kinds only, in grid order
}

@MainActor final class SocialExportModel: ObservableObject {
    struct PerImageState: Equatable {
        var zoom: CGFloat = 1
        var center = CGPoint(x: 0.5, y: 0.5)
        /// The decoded preview's pixel size. The crop rect is normalized in THIS
        /// space (that's the space the user positions it in), so the render job
        /// must be handed a rect derived from it — not from the raw file.
        var decodedSize: CGSize?
    }

    @Published var urls: [URL]
    @Published var pageIndex = 0
    @Published var preset: SocialPreset = SocialPreset.preset(id: "ig-feed-portrait") ?? SocialPreset.all[0]
    @Published var fit: SocialFit = .crop
    @Published var matte: MatteShade
    @Published var includeEXIF: Bool
    @Published var includeLocation = false   // never remembered — always reverts to OFF
    @Published var perImage: [URL: PerImageState] = [:]
    @Published var isExporting = false
    @Published var exportProgress: (Int, Int) = (0, 0)
    @Published var failures: [String] = []

    init(urls: [URL]) {
        self.urls = urls
        self.matte = MatteShade(rawValue: AppSettings.socialMatteShade) ?? .white
        self.includeEXIF = AppSettings.socialExifChoices["ig-feed-portrait"] ?? false
    }

    var currentURL: URL? { urls.indices.contains(pageIndex) ? urls[pageIndex] : nil }

    func state(for url: URL) -> PerImageState { perImage[url] ?? PerImageState() }
    func setState(_ s: PerImageState, for url: URL) { perImage[url] = s }

    func selectPreset(_ p: SocialPreset) {
        preset = p
        includeEXIF = AppSettings.socialExifChoices[p.id] ?? p.exifDefaultOn
        includeLocation = false
        // The fit control only exists for fixed-dimension presets.
        if p.isFixed == false { fit = .crop }
    }

    /// True when the source can't fill the preset's frame — the card says so
    /// rather than silently exporting something smaller than asked for.
    var willNotUpscale: Bool {
        guard let url = currentURL, let size = state(for: url).decodedSize else { return false }
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
        var choices = AppSettings.socialExifChoices
        choices[preset.id] = includeEXIF
        AppSettings.socialExifChoices = choices
        if fit == .matte || fit == .blurExtend { AppSettings.socialMatteShade = matte.rawValue }
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
        for (i, url) in urls.enumerated() {
            let s = state(for: url)
            // A crop rect is only meaningful for a fixed preset in crop mode;
            // everything else lets the renderer derive its own.
            let cropRect: CGRect? = (fit == .crop && preset.isFixed)
                ? SocialCropMath.rect(sourceSize: s.decodedSize ?? .zero,
                                      targetAspect: preset.targetAspect ?? 1,
                                      zoom: s.zoom, center: s.center)
                : nil
            let job = SocialRender.Job(sourceURL: url, preset: preset, fit: fit, matte: matte,
                                       cropRect: cropRect, includeEXIF: includeEXIF,
                                       includeLocation: includeLocation)
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try SocialRender.export(job, to: directory)
                }.value
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
struct SocialExportModal: ViewModifier {
    @EnvironmentObject private var appState: AppState

    func body(content: Content) -> some View {
        content.museModal(isPresented: Binding(
            get: { appState.socialExportRequest != nil },
            set: { if !$0 { appState.socialExportRequest = nil } }),
                          width: 760,
                          palette: appState.moodPalette) {
            if let request = appState.socialExportRequest {
                SocialExportCard(request: request) {
                    appState.socialExportRequest = nil
                }
            }
        }
    }
}

struct SocialExportCard: View {
    @StateObject private var model: SocialExportModel
    @EnvironmentObject private var appState: AppState
    let onClose: () -> Void

    init(request: SocialExportRequest, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SocialExportModel(urls: request.urls))
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Export for Social").font(.system(size: 24, weight: .semibold))
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
                SocialCropStageView(
                    url: url,
                    preset: model.preset,
                    fit: model.fit,
                    matte: model.matte,
                    state: Binding(get: { model.state(for: url) },
                                   set: { model.setState($0, for: url) }))
            } else {
                Text("Nothing to export.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.urls.count > 1 { pager }
            if model.preset.isFixed, model.fit == .crop, let url = model.currentURL {
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
            if model.preset.isFixed { fitModePicker }
            if let warning = model.preset.warningKey {
                Text(String(localized: String.LocalizationValue(warning)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            exifToggle
            Spacer(minLength: 8)
            if model.willNotUpscale {
                Text("This photo is smaller than the preset — it exports at its own size rather than being enlarged.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preset").font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { model.preset.id },
                set: { id in if let p = SocialPreset.preset(id: id) { model.selectPreset(p) } })) {
                ForEach(SocialPreset.all) { p in
                    Text(String(localized: String.LocalizationValue(p.nameKey))).tag(p.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel(Text("Preset"))
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
struct SocialCropStageView: View {
    let url: URL
    let preset: SocialPreset
    let fit: SocialFit
    let matte: MatteShade
    @Binding var state: SocialExportModel.PerImageState

    static let previewMaxPixel = 2048

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
        .accessibilityLabel(Text("Crop preview"))
    }

    @ViewBuilder
    private func content(in frame: CGSize) -> some View {
        if let image {
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
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// Story/Reel presets draw the 250/1920-fraction top and bottom bands where
    /// platform chrome covers the picture.
    @ViewBuilder
    private func safeZones(in frame: CGSize) -> some View {
        if preset.storySafeZones {
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
                guard fit == .crop, preset.isFixed, frame.width > 0, frame.height > 0 else { return }
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
        if let a = preset.targetAspect {
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
