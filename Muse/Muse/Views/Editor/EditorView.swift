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
//  Layout: a neutral backdrop, a centred canvas, and two scrollable panels of
//  section cards drawn in the Preview page's own vocabulary (EditorPanel).
//  Left is Tools / Histogram / Info / Insights / Snapshots; right is Styles /
//  Light / Tone Zones / Color. Sections open and close independently and
//  remember it globally, so the panel is as tall as the work in front of you.
//

import SwiftUI
import AppKit

struct EditorView: View {
    @ObservedObject var session: EditSession
    /// Closes the whole viewer from Edit's own ✕ — the hero owns the close
    /// flight, so it hands the action down rather than the editor reaching for
    /// AppState and skipping the choreography.
    var onClose: () -> Void = {}
    @Environment(\.theme) private var theme

    @AppStorage(AppSettings.editorBackdropKey) private var backdropRaw =
        EditorBackdropLevel.default.rawValue

    /// Which section cards are open, by id. Global, so the panel you set up for
    /// one photo is the panel you get for the next.
    @State private var expanded: Set<String> =
        AppSettings.editorExpandedSections ?? EditorView.defaultExpanded
    @State private var canvasSize: CGSize = .zero
    @State private var wipeImage: CIImage?

    // Spec 05
    @ObservedObject private var referenceStore = EditReferenceStore.shared
    /// Read only to name what's applied in the collapsed STYLES heading.
    @ObservedObject private var presetStore = EditPresetStore.shared
    @ObservedObject private var lutStore = LutStore.shared
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
    /// Pan state, mirroring HeroStage's.
    @State private var dragStartPan: CGSize?
    @State private var isDraggingPan = false
    @State private var isHoveringCanvas = false
    @State private var isHoverPushed = false
    /// The zoom a pinch started from — see `magnifyGesture`.
    @State private var magnifyStartZoom: CGFloat?
    /// 1 = panels shown, 0 = hidden. Stepped, so the canvas re-fits smoothly.
    @State private var chromeProgress: Double = 1
    @State private var chromeAnimation: Task<Void, Never>?
    private static let chromeFade: Double = 0.22
    /// Styles browser: grid or list. A global working preference.
    @AppStorage(AppSettings.editorStylesListModeKey) private var stylesListMode = false

    /// Section ids. Stable strings, because they're persisted.
    private enum Section {
        static let tools = "tools", histogram = "histogram"
        static let insights = "insights", history = "history"
        static let looks = "looks", light = "light", zones = "zones", color = "color"
    }

    /// What a first-ever editor session opens with: the tools, the histogram
    /// you judge against, the file's identity, and the sliders you reach for
    /// first. Looks is a PRESET browser — closed until asked for, like the
    /// Preview page's cards — and Tone Zones is a deliberate detour.
    private static let defaultExpanded: Set<String> =
        [Section.tools, Section.histogram, Section.insights, Section.light, Section.color]

    /// The left column's first card: level with the RIGHT column's first card,
    /// which sits below its chrome row. Also clear of the window's traffic
    /// lights, which the old 32 ran under.
    /// = 32 chrome top + 38 chrome + 12 chrome bottom pad + 14 stack spacing.
    static let panelTop: CGFloat = ViewerGeometry.chromeTop
        + ViewerGeometry.chromeHeight + 12 + 14

    /// The preset and/or LUT currently on the photo, for the collapsed STYLES
    /// heading — otherwise a closed card looks identical whether you're on
    /// Original or three looks deep.
    private var stylesSummary: String? {
        let preset = presetStore.presets.first { row in
            guard let stack = EditStackCodec.decode(row.stack) else { return false }
            return EditTransfer.isApplied(stack, onto: session.draft)
        }
        let lut = session.draft.lutParams.flatMap { applied -> String? in
            guard !applied.isNeutral else { return nil }
            return lutStore.luts.first { $0.id == applied.lutHash }?.name ?? applied.name
        }
        let names = [preset?.name, lut].compactMap { $0 }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    private var hasInsights: Bool {
        !feedbackNotes.isEmpty
            || session.draft.origin == .lightroom
            || session.draft.rawParams?.decoderVersion != nil
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { on in
                    if on { expanded.insert(id) } else { expanded.remove(id) }
                    AppSettings.editorExpandedSections = expanded
                })
    }

    /// Ink + card fill for the CURRENT backdrop, measured against WCAG AA
    /// rather than guessed from a brightness threshold. See PanelContrast.
    private var ink: PanelContrast.Ink {
        PanelContrast.resolve(backdrop: EditorBackdropLevel.resolve(backdropRaw).brightness)
    }

    /// The theme the PANELS draw in. `EditorPanel` puts this in the environment
    /// for the views it contains, but content built inline here (the Info rows,
    /// the tool rows' tint) captures colours at construction time from this
    /// view's own environment — which is the app's, not the panel's. Reading it
    /// explicitly is what keeps that text legible on the card.
    private var panelTheme: Theme { theme.onPanel(ink) }

    private var backdropLevel: Binding<EditorBackdropLevel> {
        Binding(get: { EditorBackdropLevel.resolve(backdropRaw) },
                set: { backdropRaw = $0.rawValue })
    }

    var body: some View {
        ZStack {
            EditorBackdrop(level: backdropLevel)
            // FULL BLEED. The canvas is no longer a column between the panels:
            // it spans the window and fits inside `fitInsets`, so at Fit the
            // photo sits in the free space, and zooming lets it run UNDER the
            // panels exactly as it does under the Preview column.
            canvasRegion
            HStack(alignment: .top, spacing: theme.spacingL) {
                if !session.uiHidden {
                    // No chrome on this side, so its cards start on the line
                    // the RIGHT column's first card lands on (below its chrome
                    // row) — and clear of the window's traffic lights.
                    EditorPanel(topInset: Self.panelTop, ink: ink,
                                backingVisible: isZoomed, chrome: { EmptyView() }) {
                        leftPanelContent
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                if !session.uiHidden {
                    EditorPanel(topInset: ViewerGeometry.chromeTop, ink: ink,
                                backingVisible: isZoomed, chrome: { chromeRow }) {
                        rightPanelContent
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // The Preview column's margin exactly: its cards sit
            // `columnMargin` from the window edge, and 12 of that is the
            // column's own inset — so the buttons don't shift when you switch
            // between Preview and Edit.
            .padding(.horizontal, ViewerGeometry.columnMargin - 12)
            // The hide-UI eye stays reachable when everything else is gone —
            // otherwise "show me only the image" is a one-way door.
            if session.uiHidden {
                hideUIButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.horizontal, ViewerGeometry.columnMargin - 12)
                    .padding(.top, ViewerGeometry.chromeTop)
            }
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
            chromeAnimation?.cancel()
            session.cancelCanvasAnimation()
            resetCursorState()
            session.statsVisible = false
            session.hoveredZone = nil
            session.toneZoneTargeting = false
            targetCommitTask?.cancel()
        }
        .onChange(of: expanded) { _, _ in updateStatsVisibility() }
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
        .onChange(of: session.compareEmbeddedPreview) { _, on in
            Task {
                wipeImage = on
                    ? await session.renderEmbeddedPreview()
                    : session.originalImage
            }
        }
    }

    // MARK: - Pan

    /// Drag-to-pan while zoomed, with the same open-hand / closed-fist cursors
    /// the Preview page uses — and the same push/pop discipline: a bare
    /// `.set()` is clobbered by AppKit's per-mouse-move cursor recalculation,
    /// and mismatched push/pop corrupts the stack for the whole app. See
    /// HeroStage, which this deliberately mirrors.
    private func panGesture(canvas: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                // The eyedropper and zone targeting own the drag while armed.
                guard isZoomed, !session.eyedropperArmed, !session.toneZoneTargeting
                else { return }
                if dragStartPan == nil {
                    isDraggingPan = true
                    session.cancelCanvasAnimation()
                    NSCursor.closedHand.push()
                }
                let start = dragStartPan ?? session.canvasPan
                dragStartPan = start
                session.canvasPan = ViewerGeometry.clampPan(
                    CGSize(width: start.width + value.translation.width,
                           height: start.height + value.translation.height),
                    fittedSize: fittedSize(in: canvas), zoom: session.canvasZoom)
            }
            .onEnded { _ in
                dragStartPan = nil
                guard isDraggingPan else { return }
                isDraggingPan = false
                NSCursor.pop()
            }
    }

    /// The free space the image FITS into: the window minus the two panels
    /// (and minus the chrome line at the top). Zoom is not clamped to it — the
    /// photo grows past it and under the panels, like Preview's does under the
    /// info column. Hiding the controls gives the whole window back.
    private var fitInsets: EdgeInsets {
        let column = ViewerGeometry.columnWidth + 24
            + (ViewerGeometry.columnMargin - 12) + theme.spacingL
        let bare = ViewerGeometry.sidePad
        // Interpolated, so hiding the controls GROWS the photo into the space
        // instead of snapping it there a frame later.
        let p = chromeProgress
        func lerp(_ hidden: CGFloat, _ shown: CGFloat) -> CGFloat {
            hidden + (shown - hidden) * p
        }
        return EdgeInsets(top: lerp(bare, ViewerGeometry.topPad),
                          leading: lerp(bare, column),
                          bottom: lerp(bare, ViewerGeometry.bottomPad),
                          trailing: lerp(bare, column))
    }

    /// Trackpad pinch, the same contract as the Preview page's: the gesture
    /// reports a CUMULATIVE magnification, so it multiplies the zoom the pinch
    /// started at rather than compounding every frame.
    private func magnifyGesture(canvas: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !session.eyedropperArmed, !session.toneZoneTargeting else { return }
                let start = magnifyStartZoom ?? session.canvasZoom
                if magnifyStartZoom == nil { session.cancelCanvasAnimation() }
                magnifyStartZoom = start
                let next = ViewerGeometry.clampZoom(start * value.magnification)
                session.canvasZoom = next
                session.canvasPan = ViewerGeometry.clampPan(session.canvasPan,
                                                           fittedSize: fittedSize(in: canvas),
                                                           zoom: next)
            }
            .onEnded { _ in
                magnifyStartZoom = nil
                if abs(session.canvasZoom - 1) <= 0.001 { session.canvasPan = .zero }
                syncHoverCursor()
            }
    }

    /// The image's drawn size at zoom 1 — what the pan clamp is measured
    /// against, so you can never drag the photo off its own canvas.
    private func fittedSize(in canvas: CGSize) -> CGSize {
        guard let extent = session.canvasImage?.extent,
              extent.width > 0, extent.height > 0 else { return canvas }
        let free = CGSize(width: max(1, canvas.width - fitInsets.leading - fitInsets.trailing),
                          height: max(1, canvas.height - fitInsets.top - fitInsets.bottom))
        let scale = min(free.width / extent.width, free.height / extent.height)
        return CGSize(width: extent.width * scale, height: extent.height * scale)
    }

    private func syncHoverCursor() {
        guard !isDraggingPan else { return }
        let shouldPush = isHoveringCanvas && isZoomed
            && !session.eyedropperArmed && !session.toneZoneTargeting
        if shouldPush && !isHoverPushed {
            isHoverPushed = true
            NSCursor.openHand.push()
        } else if !shouldPush && isHoverPushed {
            isHoverPushed = false
            NSCursor.pop()
        }
    }

    /// Unwinds this view's cursor pushes in LIFO order, so leaving Edit never
    /// leaves a stale hand haunting the rest of the app.
    private func resetCursorState() {
        if isDraggingPan { isDraggingPan = false; NSCursor.pop() }
        if isHoverPushed { isHoverPushed = false; NSCursor.pop() }
        isHoveringCanvas = false
    }

    // MARK: - Chrome row (zoom / Fit / hide UI / Share / close)

    /// The Preview page's chrome, in Edit: the same controls, the same 38pt
    /// sizes, drawn in the backdrop's resolved ink. Zoom drives the canvas
    /// itself — before this, Edit could only ever show a fitted image.
    private var chromeRow: some View {
        HStack(spacing: 8) {
            zoomPill
            // Same swap as Preview: zooming replaces ✕ with Fit, and the
            // buttons after the spacer slide right into the freed space.
            if isZoomed {
                ChromeTextButton(label: String(localized: "Fit"), ink: ink) {
                    session.animateCanvas(zoom: 1, pan: .zero)
                }
            }
            Spacer(minLength: 0)
            hideUIButton
            ShareButton(url: session.url, ink: ink)
            if !isZoomed {
                ChromeCircleButton(systemName: "xmark", ink: ink,
                                   accessibilityLabel: String(localized: "Close")) {
                    onClose()
                }
            }
        }
        .frame(width: ViewerGeometry.columnWidth)
    }

    private var hideUIButton: some View {
        ChromeCircleButton(systemName: session.uiHidden ? "eye.slash" : "eye",
                           ink: ink,
                           isSelected: session.uiHidden,
                           accessibilityLabel: session.uiHidden
                                ? String(localized: "Show controls")
                                : String(localized: "Hide controls")) {
            toggleChrome()
        }
        .help(Text(session.uiHidden ? "Show controls" : "Hide controls"))
    }

    /// The panels slide out and the photo grows into the space they leave.
    ///
    /// Two halves, because they animate by different means: SwiftUI moves the
    /// panels (a transition), while the canvas re-fit is a value the MTKView
    /// only reads once per render — so `chromeProgress` is stepped frame by
    /// frame, exactly like the zoom, and `fitInsets` interpolates through it.
    private func toggleChrome() {
        let hiding = !session.uiHidden
        withAnimation(.easeOut(duration: Self.chromeFade)) { session.uiHidden = hiding }
        chromeAnimation?.cancel()
        let from = chromeProgress
        let to: Double = hiding ? 0 : 1
        let frames = max(1, Int(Self.chromeFade * 60))
        chromeAnimation = Task { @MainActor in
            for frame in 1...frames {
                if Task.isCancelled { return }
                let t = Double(frame) / Double(frames)
                chromeProgress = from + (to - from) * (1 - pow(1 - t, 3))
                try? await Task.sleep(for: .milliseconds(16))
            }
            chromeProgress = to
        }
    }

    private var zoomPill: some View {
        HStack(spacing: 0) {
            ChromePillButton(systemName: "minus",
                             disabled: session.canvasZoom <= ViewerGeometry.minZoom + 0.001,
                             ink: ink) {
                setZoom(session.canvasZoom / 1.25)
            }
            Text(isZoomed ? "\(Int(session.canvasZoom * 100))%" : String(localized: "Fit"))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(ink.baseColor.opacity(0.85))
                .frame(minWidth: 38)
            ChromePillButton(systemName: "plus",
                             disabled: session.canvasZoom >= ViewerGeometry.maxZoom - 0.001,
                             ink: ink) {
                setZoom(session.canvasZoom * 1.25)
            }
        }
        .frame(height: 38)
        .background(Capsule(style: .continuous).fill(ink.cardFill))
        .clipShape(Capsule(style: .continuous))
    }

    private var isZoomed: Bool { abs(session.canvasZoom - 1) > 0.001 }

    private func setZoom(_ value: CGFloat) {
        let next = ViewerGeometry.clampZoom(value)
        session.animateCanvas(zoom: next, pan: abs(next - 1) <= 0.001 ? .zero : nil)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            EditCanvasView(image: session.displayImage,
                           wipeAgainst: wipeCompareImage,
                           wipeFraction: wipeFraction,
                           sideBySide: session.compareMode == .sideBySide,
                           zebrasOn: session.zebrasOn,
                           zoneMask: zoneMask,
                           hoveredZone: session.hoveredZone,
                           onScrollWhileTargeting: handleTargetScroll,
                           zoom: session.canvasZoom,
                           pan: session.canvasPan,
                           fitInsets: fitInsets)
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
                .overlay(alignment: .top) { sideBySideLabel }
                .gesture(panGesture(canvas: geo.size))
                .simultaneousGesture(magnifyGesture(canvas: geo.size))
                .onHover { hovering in
                    isHoveringCanvas = hovering
                    syncHoverCursor()
                }
                .onChange(of: session.canvasZoom) { _, _ in syncHoverCursor() }
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

    private func compareChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ink.baseColor)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule(style: .continuous).fill(ink.cardFill))
            .accessibilityAddTraits(.isStaticText)
    }

    /// The image being compared against — the original unless a version or the
    /// embedded Lightroom preview was chosen. Needed by BOTH compare modes;
    /// side-by-side used to get nothing, which is why it drew nothing.
    private var wipeCompareImage: CIImage? {
        switch session.compareMode {
        case .off: return nil
        case .wipe, .sideBySide: return wipeImage ?? session.originalImage
        }
    }

    private var wipeFraction: Double? {
        if case .wipe(let f) = session.compareMode { return f }
        return nil
    }

    @ViewBuilder
    private var sideBySideLabel: some View {
        if session.compareMode == .sideBySide {
            // Labels, not controls — but they sat as bare grey text on the
            // backdrop, below AA and looking like something you should be able
            // to click. Chips in the panels' own material: readable, and
            // clearly a caption.
            // One caption CENTRED over each half, so they name the two images
            // rather than floating at the far edges of the window.
            HStack(spacing: 8) {
                compareChip(String(localized: "Before")).frame(maxWidth: .infinity)
                compareChip(String(localized: "After")).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, fitInsets.leading)
            .padding(.top, ViewerGeometry.chromeTop)
        }
    }

    /// Compare, zebras, reference and reset — the TOOLS card in the left panel.
    ///
    /// This was a capsule of eight unlabelled glyphs floating under the canvas.
    /// It was too small to hit comfortably and gave no clue what any of it did,
    /// so every control now states its name and lives with the rest of the
    /// controls instead of on top of the photo.
    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            EditorToolRow(systemName: "arrow.uturn.backward",
                          label: String(localized: "Undo"),
                          isEnabled: session.canUndo) { session.undo() }
            EditorToolRow(systemName: "arrow.uturn.forward",
                          label: String(localized: "Redo"),
                          isEnabled: session.canRedo) { session.redo() }

            Divider().padding(.vertical, 4)

            // Press-and-hold, not a toggle: peek is a momentary comparison, and
            // a toggle leaves the user unsure which one they're looking at.
            // MOMENTARY: down shows the original, up puts it back. It used to
            // be a Button whose action toggled AND a press gesture that set —
            // so a click ended with the peek stuck on and no way to click it
            // off. A peek you can leave on is just a confusing second mode.
            EditorToolRow(systemName: "eye",
                          label: String(localized: "Hold to See Original"),
                          isActive: session.beforePeek,
                          onPressChanged: { pressing in session.beforePeek = pressing })

            EditorToolRow(systemName: "rectangle.split.2x1",
                          label: String(localized: "Side by Side"),
                          isActive: session.compareMode == .sideBySide) {
                session.compareMode = session.compareMode == .sideBySide ? .off : .sideBySide
            }

            EditorToolRow(systemName: "rectangle.lefthalf.inset.filled",
                          label: String(localized: "Split Compare"),
                          isActive: isWiping) {
                if case .wipe = session.compareMode {
                    session.compareMode = .off
                } else {
                    session.compareMode = .wipe(0.5)
                }
            }

            if case .wipe(let fraction) = session.compareMode {
                Slider(value: Binding(get: { fraction },
                                      set: { session.compareMode = .wipe($0) }), in: 0...1)
                    .tint(panelTheme.controlAccent)
                    .padding(.horizontal, 8)
                    .accessibilityLabel(Text("Split position"))
            }

            Divider().padding(.vertical, 4)

            // Zebras: session-scoped, J to toggle. Right-click opens the
            // thresholds, which DO persist — the stripes are a check, the
            // thresholds are a preference.
            EditorToolRow(systemName: "circle.lefthalf.striped.horizontal",
                          label: String(localized: "Clipping Zebras (J)"),
                          isActive: session.zebrasOn) { session.zebrasOn.toggle() }
                .contextMenu {
                    Button { showZebraThresholds = true } label: { Text("Zebra Thresholds…") }
                }
                .popover(isPresented: $showZebraThresholds) { ZebraThresholdsPopover() }

            EditorToolRow(systemName: "photo.on.rectangle",
                          label: String(localized: "Reference Photo"),
                          isActive: referenceStore.paneVisible,
                          isEnabled: referenceStore.url != nil) {
                referenceStore.paneVisible.toggle()
            }
            .help(Text(referenceStore.url == nil
                       ? "Right-click a photo in the grid → Use as Reference Photo"
                       : "Reference photo"))

            Divider().padding(.vertical, 4)

            EditorToolRow(systemName: "arrow.counterclockwise",
                          label: String(localized: "Reset All Adjustments")) {
                session.resetAll()
            }

            Divider().padding(.vertical, 4)

            backdropPicker
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The editor backdrop, as five visible swatches.
    ///
    /// It was reachable only by right-clicking the backdrop itself, which is a
    /// gesture nobody discovers — the setting looked like it didn't exist. The
    /// context menu still works; this is the way you can SEE.
    private var backdropPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Background")
                .font(panelTheme.labelFont)
                .foregroundStyle(panelTheme.textSecondary)
                .padding(.horizontal, 8)
            HStack(spacing: 6) {
                ForEach(EditorBackdropLevel.allCases) { level in
                    backdropSwatch(level)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 2)
    }

    private func backdropSwatch(_ level: EditorBackdropLevel) -> some View {
        let selected = EditorBackdropLevel.resolve(backdropRaw) == level
        return Button {
            backdropRaw = level.rawValue
        } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(white: level.brightness))
                .frame(width: 22, height: 22)
                // A hairline in the panel's own ink, so a white swatch on a
                // white backdrop still has an edge.
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(panelTheme.textPrimary.opacity(0.35), lineWidth: 1))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? panelTheme.controlAccent : .clear, lineWidth: 2)
                    .padding(-3))
        }
        .buttonStyle(.plain)
        .help(Text(level.label))
        .accessibilityLabel(Text(level.label))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var isWiping: Bool {
        if case .wipe = session.compareMode { return true }
        return false
    }

    // MARK: - Right card

    @ViewBuilder
    private var rightPanelContent: some View {
        // "Looks" is film-industry shorthand; this card is presets, LUTs and
        // copy/paste of adjustments — all of it "settings you saved and can
        // apply again", which is what a STYLE is in plain English (and what
        // Lightroom's French build has called it for years).
        //
        // First and closed: a style is a STARTING POINT you pick before you
        // touch a slider, and it's a browser — same rule as the Preview page's
        // cards, open it when you want it.
        EditorSection(title: String(localized: "STYLES"),
                      ink: ink,
                      accessory: stylesModeButtons,
                      summary: stylesSummary,
                      isExpanded: expansion(Section.looks)) { looksTab }
        EditorSection(title: String(localized: "LIGHT"),
                      ink: ink,
                      accessory: resetButton(String(localized: "Reset Light")) {
                          session.draft.setTone { $0 = .neutral }
                          session.draft.setPresence { $0 = .neutral }
                          session.draft.setCurve { $0 = .neutral }
                          session.commitGesture()
                      },
                      isExpanded: expansion(Section.light)) { lightTab }
        // Its own card between Light and Color: the zone strip is a distinct
        // way of working (paint tone onto the photo by zone), not one more
        // slider, and it was the tallest thing buried at the bottom of Light.
        EditorSection(title: String(localized: "TONE ZONES"),
                      ink: ink,
                      isExpanded: expansion(Section.zones)) {
            ToneZoneStrip(session: session)
        }
        EditorSection(title: String(localized: "COLOR"),
                      ink: ink,
                      accessory: resetButton(String(localized: "Reset Color")) {
                          session.draft.setColor { $0 = .neutral }
                          session.commitGesture()
                      },
                      isExpanded: expansion(Section.color)) { colorTab }
    }

    /// A card's own Reset — undoes that group and nothing else, so fixing the
    /// colour doesn't cost you the tone work.
    private func resetButton(_ help: String, action: @escaping () -> Void) -> AnyView {
        AnyView(
            EditorSmallButton(label: String(localized: "Reset"),
                              systemName: "arrow.counterclockwise",
                              action: action)
                .environment(\.theme, panelTheme)
                .help(Text(help))
        )
    }

    private var lightTab: some View {
        VStack(alignment: .leading, spacing: panelTheme.spacingS) {
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

            Text("Curve").font(panelTheme.labelFont).foregroundStyle(panelTheme.textSecondary)
            CurveEditorView(points: curveBinding,
                            // The seam Spec 04 left: the curve's backdrop is
                            // the luma channel of the SAME shared statistics
                            // pass the Scopes tab draws.
                            histogram: session.stats?.curveHistogram,
                            onCommit: session.commitGesture)
        }
    }

    private var colorTab: some View {
        VStack(alignment: .leading, spacing: panelTheme.spacingS) {
            HStack(spacing: panelTheme.spacingS) {
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
        LooksBrowserView(session: session, listMode: $stylesListMode)
    }

    /// Grid vs list for the Styles browser, as a pair of buttons in the card's
    /// HEADING — inside the card they pushed every look down by a row.
    private var stylesModeButtons: AnyView {
        AnyView(
            HStack(spacing: 4) {
                stylesModeButton(systemName: "square.grid.2x2", isOn: !stylesListMode,
                                 label: String(localized: "Grid")) { stylesListMode = false }
                stylesModeButton(systemName: "list.bullet", isOn: stylesListMode,
                                 label: String(localized: "List")) { stylesListMode = true }
            }
        )
    }

    private func stylesModeButton(systemName: String, isOn: Bool, label: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOn ? panelTheme.selectionInk : panelTheme.textPrimary)
                .frame(width: 22, height: 18)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? panelTheme.selectionFill : panelTheme.panelRaised))
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Left card

    @ViewBuilder
    private var leftPanelContent: some View {
        EditorSection(title: String(localized: "TOOLS"),
                      ink: ink,
                      isExpanded: expansion(Section.tools)) { toolsSection }
        // Was "SCOPES" — a word from broadcast video that says nothing to
        // someone looking at their own photo. It IS a histogram (plus the
        // plain-English clipping read-out), so it says so, and it sits open
        // under the tools where it can be glanced at while you work.
        EditorSection(title: String(localized: "HISTOGRAM"),
                      ink: ink,
                      isExpanded: expansion(Section.histogram)) {
            ScopesPanel(session: session)
        }
        // Moved here from the Preview column: it's feedback about how the photo
        // was exposed, which only becomes useful once you're holding the
        // sliders that answer it. Called INSIGHTS rather than the old "Why it
        // looks this way", which read like an apology.
        if hasInsights {
            EditorSection(title: String(localized: "INSIGHTS"),
                          ink: ink,
                          isExpanded: expansion(Section.insights)) { insightsSection }
        }
        EditorSection(title: String(localized: "SNAPSHOTS"),
                      ink: ink,
                      isExpanded: expansion(Section.history)) {
            EditVersionsList(session: session)
        }
    }

    /// What this card says about the photo. The INFO card that used to sit
    /// beside it was the filename (already above the panel), a count of
    /// adjustment groups (the sliders say that), and these same notes — so it
    /// went, and the two lines that were only ever there moved here.
    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Provenance: these values came from someone else's software and
            // are approximations, not a transfer.
            if session.draft.origin == .lightroom {
                Label("Approximated from Lightroom", systemImage: "info.circle")
                    .font(panelTheme.labelFont)
                    .foregroundStyle(panelTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(feedbackNotes.enumerated()), id: \.offset) { _, note in
                Text(note.displayText)
                    .font(panelTheme.labelFont)
                    .foregroundStyle(panelTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The RAW decoder version is PINNED at first edit so a later OS
            // can't silently re-render the same stack differently. When the
            // pinned one is gone we say what we substituted rather than hide it.
            if let decoderVersion = session.draft.rawParams?.decoderVersion {
                let live = RawSource.currentDecoderVersion(for: session.url)
                Text(live == nil || live == decoderVersion
                     ? String(localized: "Process: RAW decoder \(decoderVersion)")
                     : String(localized: "Process: RAW decoder \(decoderVersion) (this Mac renders with \(live ?? ""))"))
                    .font(panelTheme.labelFont)
                    .foregroundStyle(panelTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Readouts, target mode, feedback

    /// Statistics cost something, so they run only while a panel is showing
    /// them — the Light card (curve backdrop + zone mass) or Scopes. Collapsing
    /// both stops the pass, which is the point of making the cards collapsible.
    private func updateStatsVisibility() {
        let visible = expanded.contains(Section.light)
            || expanded.contains(Section.zones)      // the strip draws zone mass
            || expanded.contains(Section.histogram)
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

// `EditorCard` — the draggable single-tab panel shell — was replaced by
// `EditorPanel` + `EditorSection` (EditorPanel.swift). The drag went with it:
// a scrollable column of cards has somewhere to put everything, so there is
// nothing left to nudge out of the way.
