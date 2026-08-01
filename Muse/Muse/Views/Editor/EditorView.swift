//
//  EditorView.swift
//  Muse
//
//  The editor, living INSIDE the hero viewer as a stage swap.
//
//  It is not a new viewer and it is not a sheet: entering Edit mode replaces
//  the hero STAGE's content and hides the info column, leaving the hero's
//  open/close choreography — the flight, the parting ripple, the backdrop
//  fade, every one of its hard-won guards — completely untouched.
//
//  Layout: a neutral backdrop, a centred canvas, and two anchored floating
//  cards. Left is Info / History / Scopes (Scopes is Spec 05's mount point);
//  right is Light / Color / Looks.
//

import SwiftUI
import AppKit

struct EditorView: View {
    @ObservedObject var session: EditSession
    @Environment(\.theme) private var theme

    @AppStorage(AppSettings.editorBackdropKey) private var backdropRaw =
        EditorBackdropLevel.default.rawValue

    @State private var rightTab: RightTab = .light
    @State private var leftTab: LeftTab = .info
    @State private var canvasSize: CGSize = .zero
    @State private var wipeImage: CIImage?

    // Spec 05
    @ObservedObject private var referenceStore = EditReferenceStore.shared
    @State private var showZebraThresholds = false
    /// The smoothed-EV mask the zone hatch draws through. Built lazily on first
    /// hover and dropped whenever the draft changes — it's a per-render mask,
    /// and holding a stale one would hatch the wrong pixels.
    @State private var zoneMask: CIImage?
    @State private var zoneMaskStack: EditStack?
    @State private var referenceImage: CGImage?
    @State private var hoveredEV: Double?
    @State private var targetCommitTask: Task<Void, Never>?
    /// Feedback notes for the editor's Info tab — the same deterministic rules
    /// the hero card uses, read from precomputed columns.
    @State private var feedbackNotes: [PhotoFeedback.Note] = []

    enum RightTab: String, CaseIterable, Identifiable {
        case light, color, looks
        var id: String { rawValue }
        var label: String {
            switch self {
            case .light: String(localized: "Light")
            case .color: String(localized: "Color")
            case .looks: String(localized: "Looks")
            }
        }
    }

    enum LeftTab: String, CaseIterable, Identifiable {
        case info, history, scopes
        var id: String { rawValue }
        var label: String {
            switch self {
            case .info: String(localized: "Info")
            case .history: String(localized: "History")
            case .scopes: String(localized: "Scopes")
            }
        }
    }

    private var backdropLevel: Binding<EditorBackdropLevel> {
        Binding(get: { EditorBackdropLevel.resolve(backdropRaw) },
                set: { backdropRaw = $0.rawValue })
    }

    var body: some View {
        ZStack {
            EditorBackdrop(level: backdropLevel)
            HStack(alignment: .top, spacing: theme.spacingL) {
                EditorCard(width: 240) { leftCardContent }
                canvasRegion
                EditorCard(width: 260) { rightCardContent }
            }
            .padding(theme.spacingL)
        }
        .task(id: canvasSize) {
            guard canvasSize.width > 0 else { return }
            await session.updateCanvas(canvasLongEdge: max(canvasSize.width, canvasSize.height),
                                       scale: 2)
        }
        .onChange(of: session.draft) { _, _ in
            Task { await session.renderDraft() }
            // The zone mask describes the CURRENT stack's tone stage; a stale
            // one would hatch pixels the gains no longer act on.
            zoneMask = nil
        }
        .onAppear { updateStatsVisibility() }
        .onDisappear {
            session.statsVisible = false
            session.hoveredZone = nil
            session.toneZoneTargeting = false
            targetCommitTask?.cancel()
        }
        .onChange(of: leftTab) { _, _ in updateStatsVisibility() }
        .onChange(of: rightTab) { _, _ in updateStatsVisibility() }
        .onChange(of: session.hoveredZone) { _, zone in
            guard zone != nil else { return }
            Task { await buildZoneMaskIfNeeded() }
        }
        .task(id: session.url) { await loadFeedback() }
        .onChange(of: session.wipeAgainst) { _, stack in
            Task {
                guard let stack else {
                    wipeImage = session.originalImage
                    return
                }
                wipeImage = await session.renderComparison(stack)
            }
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            EditCanvasView(image: session.displayImage,
                           wipeAgainst: wipeCompareImage,
                           wipeFraction: wipeFraction,
                           zebrasOn: session.zebrasOn,
                           zoneMask: zoneMask,
                           hoveredZone: session.hoveredZone,
                           onScrollWhileTargeting: handleTargetScroll)
                .onAppear { canvasSize = geo.size }
                .onChange(of: geo.size) { _, size in canvasSize = size }
                // The eyedropper is a MODE, not a persistent overlay: it
                // swallows one click and disarms, so a stray second click
                // can't silently re-sample.
                .overlay {
                    if session.eyedropperArmed {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                sampleWhiteBalance(at: location, canvas: geo.size)
                            }
                    }
                }
                .overlay(alignment: .bottom) { compareChrome }
                .overlay(alignment: .top) { sideBySideLabel }
                .overlay(alignment: .topLeading) { targetReadout }
                .onContinuousHover { phase in
                    handleTargetHover(phase, canvas: geo.size)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The canvas, optionally split with the pinned reference photo. The
    /// reference is hidden while a before/after compare is running: two
    /// simultaneous comparisons is one too many to reason about.
    @ViewBuilder
    private var canvasRegion: some View {
        if referenceStore.paneVisible, let refURL = referenceStore.url,
           session.compareMode == .off {
            HStack(spacing: 1) {
                referencePane(url: refURL)
                canvas
            }
        } else {
            canvas
        }
    }

    private func referencePane(url: URL) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let referenceImage {
                Image(decorative: referenceImage, scale: 1)
                    .resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
            Text(url.lastPathComponent)
                .font(theme.labelFont)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .padding(theme.spacingS)
                .background(theme.panelFill, in: RoundedRectangle(cornerRadius: theme.radius))
                .padding(theme.spacingM)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            // Rendered THROUGH ITS OWN edit stack: a reference carrying Muse
            // edits has to look the way it looks everywhere else, or it isn't
            // a reference. Fit-only — no zoom/pan sync in v1.
            referenceImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let stack = EditStackIndex.resolvedStack(for: url) ?? .fresh()
                return EditRenderer.render(url: url, stack: stack, maxPixel: 1024)
            }.value
        }
    }

    /// The floating EV/zone readout shown while targeting on the canvas.
    @ViewBuilder
    private var targetReadout: some View {
        if session.toneZoneTargeting, let ev = hoveredEV, let zone = session.hoveredZone {
            Text(String(format: "%.1f EV · ", ev) + String(localized: "Zone \(zone + 1)"))
                .font(theme.valueFont)
                .foregroundStyle(theme.textPrimary)
                .padding(theme.spacingS)
                .background(theme.panelFill, in: RoundedRectangle(cornerRadius: theme.radius))
                .padding(theme.spacingM)
        }
    }

    private var wipeCompareImage: CIImage? {
        guard case .wipe = session.compareMode else { return nil }
        return wipeImage ?? session.originalImage
    }

    private var wipeFraction: Double? {
        if case .wipe(let f) = session.compareMode { return f }
        return nil
    }

    @ViewBuilder
    private var sideBySideLabel: some View {
        if session.compareMode == .sideBySide {
            HStack {
                Text("Before").font(theme.labelFont)
                Spacer()
                Text("After").font(theme.labelFont)
            }
            .foregroundStyle(theme.textSecondary)
            .padding(theme.spacingM)
        }
    }

    /// Compare + undo chrome, under the canvas.
    private var compareChrome: some View {
        HStack(spacing: theme.spacingM) {
            Button {
                session.undo()
            } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!session.canUndo)
                .help(Text("Undo"))
                .accessibilityLabel(Text("Undo"))

            Button {
                session.redo()
            } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!session.canRedo)
                .help(Text("Redo"))
                .accessibilityLabel(Text("Redo"))

            Divider().frame(height: 14)

            // Press-and-hold, not a toggle: peek is a momentary comparison, and
            // a toggle leaves the user unsure which one they're looking at.
            Image(systemName: "eye")
                .foregroundStyle(session.beforePeek ? theme.controlAccent : theme.textPrimary)
                .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) {
                } onPressingChanged: { pressing in
                    session.beforePeek = pressing
                }
                .help(Text("Hold to see the original"))
                .accessibilityLabel(Text("Show original"))
                .accessibilityAction(named: Text("Show original")) {
                    session.beforePeek.toggle()
                }

            Button {
                session.compareMode = session.compareMode == .sideBySide ? .off : .sideBySide
            } label: { Image(systemName: "rectangle.split.2x1") }
                .help(Text("Side by side"))
                .accessibilityLabel(Text("Side by side"))

            Button {
                if case .wipe = session.compareMode {
                    session.compareMode = .off
                } else {
                    session.compareMode = .wipe(0.5)
                }
            } label: { Image(systemName: "rectangle.lefthalf.inset.filled") }
                .help(Text("Split compare"))
                .accessibilityLabel(Text("Split compare"))

            if case .wipe(let fraction) = session.compareMode {
                Slider(value: Binding(get: { fraction },
                                      set: { session.compareMode = .wipe($0) }), in: 0...1)
                    .frame(width: 120)
                    .tint(theme.controlAccent)
                    .accessibilityLabel(Text("Split position"))
            }

            Divider().frame(height: 14)

            // Zebras: session-scoped, J to toggle. Right-click opens the
            // thresholds, which DO persist — the stripes are a check, the
            // thresholds are a preference.
            Button {
                session.zebrasOn.toggle()
            } label: { Image(systemName: "circle.lefthalf.striped.horizontal") }
                .foregroundStyle(session.zebrasOn ? theme.controlAccent : theme.textPrimary)
                .help(Text("Clipping zebras (J)"))
                .accessibilityLabel(Text("Clipping zebras"))
                .contextMenu {
                    Button { showZebraThresholds = true } label: { Text("Zebra Thresholds…") }
                }
                .popover(isPresented: $showZebraThresholds) { ZebraThresholdsPopover() }

            Button {
                referenceStore.paneVisible.toggle()
            } label: { Image(systemName: "photo.on.rectangle") }
                .foregroundStyle(referenceStore.paneVisible ? theme.controlAccent : theme.textPrimary)
                .disabled(referenceStore.url == nil)
                .help(Text(referenceStore.url == nil
                           ? "Right-click a photo in the grid → Use as Reference Photo"
                           : "Reference photo"))
                .accessibilityLabel(Text("Reference photo"))

            Divider().frame(height: 14)

            Button {
                session.resetAll()
            } label: { Text("Reset") }
                .font(theme.labelFont)
                .help(Text("Reset all adjustments"))
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, theme.spacingM)
        .padding(.vertical, theme.spacingS)
        .background(theme.panelFill, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).stroke(theme.panelStroke))
        .padding(theme.spacingM)
    }

    // MARK: - Right card

    @ViewBuilder
    private var rightCardContent: some View {
        Picker("", selection: $rightTab) {
            ForEach(RightTab.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        ScrollViewReader { _ in
            VStack(alignment: .leading, spacing: theme.spacingM) {
                switch rightTab {
                case .light: lightTab
                case .color: colorTab
                case .looks: looksTab
                }
            }
        }
    }

    private var lightTab: some View {
        VStack(alignment: .leading, spacing: theme.spacingS) {
            EditSlider(label: String(localized: "Exposure"),
                       value: toneBinding(\.exposureEV),
                       range: ToneParams.exposureRange, onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Contrast"),
                       value: toneBinding(\.contrast), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Highlights"),
                       value: toneBinding(\.highlights), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Shadows"),
                       value: toneBinding(\.shadows), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Whites"),
                       value: toneBinding(\.whites), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Blacks"),
                       value: toneBinding(\.blacks), onCommit: session.commitGesture)

            Divider()

            EditSlider(label: String(localized: "Clarity"),
                       value: presenceBinding(\.clarity), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Texture"),
                       value: presenceBinding(\.texture), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Sharpen"),
                       value: presenceBinding(\.sharpen), range: 0...1,
                       onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Noise Reduction"),
                       value: presenceBinding(\.noiseReduction), range: 0...1,
                       onCommit: session.commitGesture)

            Divider()

            ToneZoneStrip(session: session)

            Divider()

            Text("Curve").font(theme.labelFont).foregroundStyle(theme.textSecondary)
            CurveEditorView(points: curveBinding,
                            // The seam Spec 04 left: the curve's backdrop is
                            // the luma channel of the SAME shared statistics
                            // pass the Scopes tab draws.
                            histogram: session.stats?.curveHistogram,
                            onCommit: session.commitGesture)
        }
    }

    private var colorTab: some View {
        VStack(alignment: .leading, spacing: theme.spacingS) {
            HStack(spacing: theme.spacingS) {
                EditSlider(label: String(localized: "Temperature"),
                           value: colorBinding(\.temperature), onCommit: session.commitGesture)
                WBEyedropperButton(session: session)
            }
            EditSlider(label: String(localized: "Tint"),
                       value: colorBinding(\.tint), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Vibrance"),
                       value: colorBinding(\.vibrance), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Saturation"),
                       value: colorBinding(\.saturation), onCommit: session.commitGesture)

            if session.isRaw {
                Divider()
                EditToggleRow(label: String(localized: "Auto Lens Correction"),
                              isOn: Binding(
                                get: { session.draft.rawParams?.lensCorrection ?? true },
                                set: { on in session.draft.setRaw { $0.lensCorrection = on } }),
                              onCommit: session.commitGesture)
            }
        }
    }

    private var looksTab: some View {
        LooksBrowserView(session: session)
    }

    // MARK: - Left card

    @ViewBuilder
    private var leftCardContent: some View {
        Picker("", selection: $leftTab) {
            ForEach(LeftTab.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        switch leftTab {
        case .info: infoTab
        case .history: EditVersionsList(session: session)
        case .scopes: ScopesPanel(session: session)
        }
    }

    private var infoTab: some View {
        VStack(alignment: .leading, spacing: theme.spacingS) {
            Text(session.url.lastPathComponent)
                .font(theme.labelFont)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
            let groups = EditTransfer.adjustedGroups(of: session.draft)
            if groups.isEmpty {
                Text("No adjustments")
                    .font(theme.labelFont)
                    .foregroundStyle(theme.textSecondary)
            } else {
                Text(String(format: NSLocalizedString(
                    "%lld adjustment groups", comment: "editor Info card summary"),
                            groups.count))
                    .font(theme.labelFont)
                    .foregroundStyle(theme.textSecondary)
            }

            if !feedbackNotes.isEmpty {
                Divider()
                ForEach(Array(feedbackNotes.enumerated()), id: \.offset) { _, note in
                    Text(note.displayText)
                        .font(theme.labelFont)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // The RAW decoder version is PINNED at first edit so a later OS
            // can't silently re-render the same stack differently. When the
            // pinned one is gone we say what we substituted rather than hide it.
            if let decoderVersion = session.draft.rawParams?.decoderVersion {
                let live = RawSource.currentDecoderVersion(for: session.url)
                Divider()
                Text(live == nil || live == decoderVersion
                     ? String(localized: "Process: RAW decoder \(decoderVersion)")
                     : String(localized: "Process: RAW decoder \(decoderVersion) (this Mac renders with \(live ?? ""))"))
                    .font(theme.labelFont)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Readouts, target mode, feedback

    /// Statistics cost something, so they run only while a panel is showing
    /// them — the Light tab (curve backdrop + zone mass) or Scopes.
    private func updateStatsVisibility() {
        let visible = rightTab == .light || leftTab == .scopes
        session.statsVisible = visible
        if visible {
            session.refreshStats()
        } else {
            session.hoveredZone = nil
        }
    }

    /// Build the hatch overlay's mask for the current draft. Lazy — most
    /// sessions never hover a zone, and this is a decode.
    private func buildZoneMaskIfNeeded() async {
        guard zoneMask == nil || zoneMaskStack != session.draft else { return }
        let url = session.url
        let stack = session.draft
        let edge = max(Int(max(canvasSize.width, canvasSize.height)), 1)
        let mask = await Task.detached(priority: .userInitiated) { () -> CIImage? in
            guard let toneStage = EditRenderer.toneStageImage(url: url, stack: stack,
                                                              maxPixel: edge)
            else { return nil }
            return ToneZoneFilter.smoothedEVMap(for: toneStage, longEdge: CGFloat(edge))
        }.value
        guard session.draft == stack else { return }
        zoneMask = mask
        zoneMaskStack = stack
    }

    /// Target mode: hovering the canvas reads the SMOOTHED mask's EV, so the
    /// number shown is the number the scroll wheel then moves.
    private func handleTargetHover(_ phase: HoverPhase, canvas: CGSize) {
        guard session.toneZoneTargeting else { return }
        switch phase {
        case .active(let location):
            NSCursor.crosshair.set()
            guard let ev = sampleEV(at: location, canvas: canvas) else { return }
            hoveredEV = ev
            session.hoveredZone = ToneZoneMath.zoneIndex(forEV: ev)
        case .ended:
            NSCursor.arrow.set()
            hoveredEV = nil
            session.hoveredZone = nil
        @unknown default:
            break
        }
    }

    private func sampleEV(at point: CGPoint, canvas: CGSize) -> Double? {
        guard let map = session.zoneEVMap, map.width > 0, map.height > 0,
              let image = session.canvasImage else { return nil }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let fitScale = min(canvas.width / extent.width, canvas.height / extent.height)
        let fit = CGRect(x: (canvas.width - extent.width * fitScale) / 2,
                         y: (canvas.height - extent.height * fitScale) / 2,
                         width: extent.width * fitScale, height: extent.height * fitScale)
        guard let unit = CanvasPointMath.imagePoint(fromCanvasPoint: point, fit: fit,
                                                    zoom: session.canvasZoom,
                                                    pan: session.canvasPan)
        else { return nil }
        let x = min(max(Int(unit.x * Double(map.width)), 0), map.width - 1)
        let y = min(max(Int(unit.y * Double(map.height)), 0), map.height - 1)
        return Double(map.values[y * map.width + x])
    }

    /// Scroll adjusts the hovered zone while targeting, and is CONSUMED so the
    /// canvas doesn't zoom underneath the gesture.
    private func handleTargetScroll(_ event: NSEvent) -> Bool {
        guard session.toneZoneTargeting, let zone = session.hoveredZone else { return false }
        let scrollGainPerTick = 0.02
        let deltaY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        session.draft.setToneZone { params in
            var gains = params.clamped().gains
            gains[zone] = min(max(gains[zone] + Double(deltaY) * scrollGainPerTick, -1), 1)
            params = ToneZoneParams(gains: gains)
        }
        // One history entry per burst of scrolling, matching the slider's
        // push-on-gesture-end contract.
        targetCommitTask?.cancel()
        targetCommitTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            session.commitGesture()
        }
        return true
    }

    private func loadFeedback() async {
        let path = session.url.path
        feedbackNotes = await Task.detached(priority: .utility) { () -> [PhotoFeedback.Note] in
            guard let queue = Database.shared.dbQueue,
                  let inputs = try? queue.read({ db in
                      try PhotoStatsQueries.feedbackInputs(path: path, db: db)
                  }) ?? nil
            else { return [] }
            return PhotoFeedback.notes(for: inputs)
        }.value
    }

    // MARK: - Eyedropper

    /// Sample the PROXY the canvas is already showing, map the pixel to a
    /// temperature/tint pair, and store those as ordinary slider values.
    ///
    /// The stack stays declarative: what's stored is the resulting offsets,
    /// never the click location. A stored location would have to be re-sampled
    /// on every render and would point somewhere else the moment a crop moved.
    private func sampleWhiteBalance(at location: CGPoint, canvas: CGSize) {
        session.eyedropperArmed = false
        guard let image = session.originalImage ?? session.canvasImage else { return }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        let fitScale = min(canvas.width / extent.width, canvas.height / extent.height)
        let fit = CGRect(x: (canvas.width - extent.width * fitScale) / 2,
                         y: (canvas.height - extent.height * fitScale) / 2,
                         width: extent.width * fitScale, height: extent.height * fitScale)
        guard let unit = CanvasPointMath.imagePoint(fromCanvasPoint: location, fit: fit,
                                                    zoom: session.canvasZoom,
                                                    pan: session.canvasPan)
        else { return }   // clicked the backdrop: sampling it would set WB from grey

        // CIImage's origin is bottom-left; the click's is top-left.
        let px = extent.minX + CGFloat(unit.x) * extent.width
        let py = extent.minY + CGFloat(1 - unit.y) * extent.height
        var bytes = [UInt8](repeating: 0, count: 4)
        RenderContexts.preview.render(
            image, toBitmap: &bytes, rowBytes: 4,
            bounds: CGRect(x: px, y: py, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let solved = WBEyedropper.solve(sampledColor: (r: Double(bytes[0]) / 255,
                                                       g: Double(bytes[1]) / 255,
                                                       b: Double(bytes[2]) / 255))
        session.draft.setColor {
            $0.temperature = solved.temperature
            $0.tint = solved.tint
        }
        session.commitGesture()
    }

    // MARK: - Bindings

    /// Each binding reads through the typed accessor and writes through the
    /// find-or-insert mutator, so touching a slider creates its adjustment
    /// case and nothing else has to know the stack's shape.
    private func toneBinding(_ keyPath: WritableKeyPath<ToneParams, Double>) -> Binding<Double> {
        Binding(get: { session.draft.toneParams?[keyPath: keyPath] ?? 0 },
                set: { v in session.draft.setTone { $0[keyPath: keyPath] = v } })
    }

    private func colorBinding(_ keyPath: WritableKeyPath<ColorParams, Double>) -> Binding<Double> {
        Binding(get: { session.draft.colorParams?[keyPath: keyPath] ?? 0 },
                set: { v in session.draft.setColor { $0[keyPath: keyPath] = v } })
    }

    private func presenceBinding(_ keyPath: WritableKeyPath<PresenceParams, Double>) -> Binding<Double> {
        Binding(get: { session.draft.presenceParams?[keyPath: keyPath] ?? 0 },
                set: { v in session.draft.setPresence { $0[keyPath: keyPath] = v } })
    }

    private var curveBinding: Binding<[CurveParams.Point]> {
        Binding(get: { session.draft.curveParams?.rgb ?? [] },
                set: { pts in session.draft.setCurve { $0.rgb = pts } })
    }
}

/// Zebra thresholds. These persist (unlike the toggle) because they are a
/// judgement about what counts as clipped, not a momentary check — and they
/// are the SAME values the Scopes percentages and the stored-stat-free live
/// statistics read.
private struct ZebraThresholdsPopover: View {
    @State private var high = AppSettings.editorZebraHigh
    @State private var low = AppSettings.editorZebraLow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading) {
                Text("Over").font(.caption)
                Slider(value: $high, in: 0.90...1.00) { editing in
                    if !editing {
                        UserDefaults.standard.set(high, forKey: AppSettings.editorZebraHighKey)
                    }
                }
            }
            VStack(alignment: .leading) {
                Text("Under").font(.caption)
                Slider(value: $low, in: 0.00...0.10) { editing in
                    if !editing {
                        UserDefaults.standard.set(low, forKey: AppSettings.editorZebraLowKey)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 220)
    }
}

/// The floating panel shell — one definition, so the two cards can't drift.
/// Draggable with snap-back: nothing about the position is persisted, because
/// a card the user nudged out of the way three sessions ago is a bug report.
struct EditorCard<Content: View>: View {
    let width: CGFloat
    @ViewBuilder var content: Content

    @Environment(\.theme) private var theme
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingM) {
            content
            Spacer(minLength: 0)
        }
        .padding(theme.spacingM)
        .frame(width: width)
        .background(theme.panelFill, in: RoundedRectangle(cornerRadius: theme.radius))
        .overlay(RoundedRectangle(cornerRadius: theme.radius).stroke(theme.panelStroke))
        .offset(dragOffset)
        .gesture(
            DragGesture()
                .onChanged { dragOffset = $0.translation }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.35, bounce: 0.2)) { dragOffset = .zero }
                }
        )
    }
}
