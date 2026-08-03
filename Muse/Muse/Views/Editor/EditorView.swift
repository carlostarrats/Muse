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
    @Environment(\.theme) var theme

    @AppStorage(AppSettings.editorBackdropKey) var backdropRaw =
        EditorBackdropLevel.default.rawValue

    /// Which section cards are open, by id. Global, so the panel you set up for
    /// one photo is the panel you get for the next.
    @State var expanded: Set<String> =
        AppSettings.editorExpandedSections ?? EditorView.defaultExpanded
    @State var canvasSize: CGSize = .zero
    @State var wipeImage: CIImage?

    // Spec 05
    /// Read only to name what's applied in the collapsed STYLES heading.
    @ObservedObject var presetStore = EditPresetStore.shared
    @ObservedObject var lutStore = LutStore.shared
    /// The View menu's half of the hide-UI eye — see `EditorChromeCommand`.
    @ObservedObject var chromeCommand = EditorChromeCommand.shared
    /// The panel layout — which cards, where, and which are hidden.
    @ObservedObject var workspace = EditorWorkspaceStore.shared
    @State var showZebraThresholds = false
    /// The smoothed-EV mask the zone hatch draws through. Built lazily on first
    /// hover and dropped whenever the draft changes — it's a per-render mask,
    /// and holding a stale one would hatch the wrong pixels.
    @State var zoneMask: CIImage?
    @State var zoneMaskStack: EditStack?
    @State var hoveredEV: Double?
    @State var targetCommitTask: Task<Void, Never>?
    /// Feedback notes for the editor's Info tab — the same deterministic rules
    /// the hero card uses, read from precomputed columns.
    @State var feedbackNotes: [PhotoFeedback.Note] = []
    /// Pan state, mirroring HeroStage's.
    @State var dragStartPan: CGSize?
    @State var isDraggingPan = false
    @State var isHoveringCanvas = false
    @State var isHoverPushed = false
    /// The zoom a pinch started from — see `magnifyGesture`.
    @State var magnifyStartZoom: CGFloat?
    /// 1 = panels shown, 0 = hidden. Stepped, so the canvas re-fits smoothly.
    @State var chromeProgress: Double = 1
    @State var chromeAnimation: Task<Void, Never>?
    static let chromeFade: Double = 0.22
    /// Styles browser: grid or list. A global working preference.
    @AppStorage(AppSettings.editorStylesListModeKey) var stylesListMode = false
    /// Session-scoped: which channel COLOR MIX is showing. Saturation first —
    /// it is the one people reach for.
    @State var hslTab: HSLTab = .saturation
    /// Crop: the chosen shape and whether it is stood on end. One entry per
    /// shape plus an orientation toggle, rather than two entries per shape.
    @State var cropAspect: CropAspectPreset = .original
    @State var cropPortrait = false
    @State var applyCropHovering = false

    /// Section ids. Stable strings, because they're persisted.
    enum Section {
        static let tools = "tools", histogram = "histogram"
        static let insights = "insights", history = "history"
        static let looks = "looks", light = "light", zones = "zones", color = "color"
        static let hsl = "hsl", splitTone = "splitTone", effects = "effects"
        static let crop = "crop"
    }

    /// What a first-ever editor session opens with: the tools, the histogram
    /// you judge against, the file's identity, and the sliders you reach for
    /// first. Looks is a PRESET browser — closed until asked for, like the
    /// Preview page's cards — and Tone Zones is a deliberate detour.
    static let defaultExpanded: Set<String> =
        [Section.tools, Section.histogram, Section.insights, Section.light, Section.color]

    /// The left column's first card: level with the RIGHT column's first card,
    /// which sits below its chrome row. Also clear of the window's traffic
    /// lights, which the old 32 ran under.
    /// = 32 chrome top + 38 chrome + 12 chrome bottom pad + 14 stack spacing.
    static let panelTop: CGFloat = ViewerGeometry.chromeTop
        + ViewerGeometry.chromeHeight + 12 + 14

    func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { on in
                    if on { expanded.insert(id) } else { expanded.remove(id) }
                    AppSettings.editorExpandedSections = expanded
                })
    }

    /// Ink + card fill for the CURRENT backdrop, measured against WCAG AA
    /// rather than guessed from a brightness threshold. See PanelContrast.
    var ink: PanelContrast.Ink {
        PanelContrast.resolve(backdrop: EditorBackdropLevel.resolve(backdropRaw).brightness)
    }

    /// The theme the PANELS draw in. `EditorPanel` puts this in the environment
    /// for the views it contains, but content built inline here (the Info rows,
    /// the tool rows' tint) captures colours at construction time from this
    /// view's own environment — which is the app's, not the panel's. Reading it
    /// explicitly is what keeps that text legible on the card.
    var panelTheme: Theme { theme.onPanel(ink) }

    var backdropLevel: Binding<EditorBackdropLevel> {
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
                // The LEFT column stops drawing when the workspace has moved
                // everything off it — an empty panel would leave a dead strip
                // beside the photo instead of giving the space back.
                if !session.uiHidden && !workspace.active.isEmpty(.left) {
                    // No chrome on this side, so its cards start on the line
                    // the RIGHT column's first card lands on (below its chrome
                    // row) — and clear of the window's traffic lights.
                    EditorPanel(topInset: Self.panelTop, ink: ink,
                                backingVisible: isZoomed, chrome: { EmptyView() }) {
                        columnContent(.left)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                // The RIGHT column ALWAYS draws, even with no cards on it: it
                // carries the chrome row, and zoom / the eye / Share / ✕ are
                // viewer controls, not modules. They stay pinned top-right
                // whatever happens to the cards — which is what makes an
                // all-cards-left layout coherent. With nothing on it this
                // renders the chrome row alone over the canvas, exactly what
                // the hide-UI eye already produces.
                if !session.uiHidden {
                    EditorPanel(topInset: ViewerGeometry.chromeTop, ink: ink,
                                backingVisible: isZoomed, chrome: { chromeRow }) {
                        columnContent(.right)
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
            // Settle before rebuilding. `.task(id:)` cancels and restarts on
            // every canvas change, so a sleep at the top IS the debounce: while
            // a drag is in flight each new size cancels the pending rebuild
            // here, at the await, BEFORE any decode or render has been started.
            // Without it the proxy rebuild raced the drag — see the ladder note
            // on `EditSession.proxyMaxPixel`. Between rungs of that ladder this
            // is a no-op anyway; the pairing matters when a drag crosses one.
            // …but only once there IS a proxy. On mount there is nothing to
            // race, and the debounce was pure dead time in front of the first
            // decode — 120 ms of empty canvas on every entry to Edit.
            if session.hasProxy {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else {
                    return
                }
            }
            await session.updateCanvas(canvasLongEdge: max(canvasSize.width, canvasSize.height),
                                       scale: 2)
        }
        .onChange(of: session.draft) { _, _ in
            Task { await session.renderDraft() }
            // The zone mask describes the CURRENT stack's tone stage; a stale
            // one would hatch pixels the gains no longer act on.
            zoneMask = nil
        }
        .onAppear {
            updateStatsVisibility()
            chromeCommand.editorPresented(uiHidden: session.uiHidden)
        }
        .onDisappear {
            chromeAnimation?.cancel()
            session.cancelCanvasAnimation()
            resetCursorState()
            session.statsVisible = false
            session.hoveredZone = nil
            session.toneZoneTargeting = false
            targetCommitTask?.cancel()
            // Leaves the View menu's item disabled and correctly titled for the
            // next visit, whichever state this one ended in.
            chromeCommand.editorDismissed()
            // Leaving the editor by any route discards an in-flight
            // rearrangement and closes the Customize card — see the store.
            workspace.editorDismissed()
        }
        // The menu item is the SAME action as the eye, so it goes through the
        // same animated toggle rather than setting `uiHidden` behind its back —
        // a bare assignment would slide the panels without stepping the canvas
        // insets, and the photo would jump instead of growing into the space.
        .onChange(of: chromeCommand.toggleRequests) { _, _ in toggleChrome() }
        .onChange(of: session.uiHidden) { _, hidden in
            chromeCommand.editorPresented(uiHidden: hidden)
        }
        .onChange(of: expanded) { _, _ in updateStatsVisibility() }
        // A column gaining or losing its last card changes the photo's fit.
        // Stepped rather than animated, because the canvas reads the insets
        // once per render — see stepCanvasRefit.
        .onChange(of: workspace.active.isEmpty(.left)) { _, _ in stepCanvasRefit() }
        .onChange(of: workspace.active.isEmpty(.right)) { _, _ in stepCanvasRefit() }
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
    func panGesture(canvas: CGSize) -> some Gesture {
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
    var fitInsets: EdgeInsets {
        // Sides follow the cards, the top stays with the chrome — and the whole
        // thing is interpolated through `chromeProgress`, so hiding the
        // controls GROWS the photo into the space instead of snapping it there
        // a frame later. See EditorCanvasGeometry.panelInsets.
        EditorCanvasGeometry.panelInsets(leftEmpty: workspace.active.isEmpty(.left),
                                         rightEmpty: workspace.active.isEmpty(.right),
                                         chromeProgress: chromeProgress)
    }

    /// Trackpad pinch, the same contract as the Preview page's: the gesture
    /// reports a CUMULATIVE magnification, so it multiplies the zoom the pinch
    /// started at rather than compounding every frame.
    func magnifyGesture(canvas: CGSize) -> some Gesture {
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

    /// The content's drawn size at zoom 1 — what the pan clamp is measured
    /// against, so you can never drag the photo off its own canvas. Shares
    /// `EditorCanvasGeometry` with the layout itself, rather than re-deriving
    /// the same fit a second time.
    func fittedSize(in canvas: CGSize) -> CGSize {
        EditorCanvasGeometry.fittedSize(canvas: canvas, insets: fitInsets,
                                        aspect: contentAspect)
    }

    func syncHoverCursor() {
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
    func resetCursorState() {
        if isDraggingPan { isDraggingPan = false; NSCursor.pop() }
        if isHoverPushed { isHoverPushed = false; NSCursor.pop() }
        isHoveringCanvas = false
    }

    // MARK: - Chrome row (zoom / Fit / hide UI / Share / close)

    /// The Preview page's chrome, in Edit: the same controls, the same 38pt
    /// sizes, drawn in the backdrop's resolved ink. Zoom drives the canvas
    /// itself — before this, Edit could only ever show a fitted image.
    var chromeRow: some View {
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

    var hideUIButton: some View {
        ChromeCircleButton(systemName: session.uiHidden ? "eye.slash" : "eye",
                           ink: ink,
                           isSelected: session.uiHidden,
                           accessibilityLabel: session.uiHidden
                                ? String(localized: "Show controls")
                                : String(localized: "Hide controls")) {
            toggleChrome()
        }
        // ⌘U is NOT here — it lives on the View menu's item, which is where a
        // Mac user looks up a shortcut. A second copy on this button would be a
        // duplicate key equivalent in the same window.
        .help(Text(session.uiHidden ? "Show controls" : "Hide controls"))
    }

    /// The panels slide out and the photo grows into the space they leave.
    ///
    /// Two halves, because they animate by different means: SwiftUI moves the
    /// panels (a transition), while the canvas re-fit is a value the MTKView
    /// only reads once per render — so `chromeProgress` is stepped frame by
    /// frame, exactly like the zoom, and `fitInsets` interpolates through it.
    func toggleChrome() {
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

    /// Re-fit the canvas after the COLUMNS changed shape (a Save that emptied
    /// one, or Default Layout putting it back).
    ///
    /// `fitInsets` is a value the MTKView reads once per render, so a plain
    /// SwiftUI animation would never reach it — the same reason `toggleChrome`
    /// steps `chromeProgress` frame by frame instead of animating it. Nothing
    /// about the progress itself changes here; re-publishing it on each frame
    /// for the length of the panel transition is what makes the photo GLIDE
    /// into the freed space rather than jump there once the layout settles.
    func stepCanvasRefit() {
        // While the UI is hidden the insets are already bare on every side, so
        // there is nothing to animate toward.
        guard !session.uiHidden else { return }
        chromeAnimation?.cancel()
        let frames = max(1, Int(Self.chromeFade * 60))
        chromeAnimation = Task { @MainActor in
            for _ in 1...frames {
                if Task.isCancelled { return }
                chromeProgress = 1
                try? await Task.sleep(for: .milliseconds(16))
            }
            chromeProgress = 1
        }
    }

    var zoomPill: some View {
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

    var isZoomed: Bool { abs(session.canvasZoom - 1) > 0.001 }

    func setZoom(_ value: CGFloat) {
        let next = ViewerGeometry.clampZoom(value)
        // Clamp the pan to the NEW zoom: zooming out with a pan applied would
        // otherwise leave the photo hanging off its own canvas, since a smaller
        // zoom allows a smaller offset. The hero's setZoom does the same.
        let pan = abs(next - 1) <= 0.001
            ? .zero
            : ViewerGeometry.clampPan(session.canvasPan,
                                      fittedSize: fittedSize(in: canvasSize), zoom: next)
        session.animateCanvas(zoom: next, pan: pan)
    }

    // MARK: - Canvas

    var canvas: some View {
        GeometryReader { geo in
            // The canvas view is SIZED TO THE CONTENT and positioned, exactly
            // as the Preview page lays out its `Image`. Zoom scales this frame
            // and pan moves it — deliberately unclamped to the free rect, so a
            // zoomed photo grows past it and runs UNDER the panels (they are
            // drawn later in the parent ZStack).
            let content = EditorCanvasGeometry.contentRect(
                canvas: geo.size, insets: fitInsets, aspect: contentAspect,
                zoom: session.canvasZoom, pan: session.canvasPan)
            ZStack {
                // The gesture surface stays window-sized: pan and pinch worked
                // anywhere on the backdrop when the Metal view spanned the
                // window, and shrinking the view to the photo must not quietly
                // shrink where you can grab it. BELOW the canvas, so the
                // eyedropper's overlay still gets clicks on the photo first.
                Color.clear.contentShape(Rectangle())

                EditCanvasView(image: session.displayImage,
                               wipeAgainst: wipeCompareImage,
                               wipeFraction: wipeFraction,
                               sideBySide: session.compareMode == .sideBySide,
                               zebrasOn: session.zebrasOn,
                               zoneMask: zoneMask,
                               hoveredZone: session.hoveredZone,
                               onScrollWhileTargeting: handleTargetScroll)
                    .frame(width: content.width, height: content.height)
                    // The eyedropper is a MODE, not a persistent overlay: it
                    // swallows one click and disarms, so a stray second click
                    // can't silently re-sample. On the CANVAS, so the point is
                    // already in content space — a click on the backdrop simply
                    // misses it instead of being mapped to an edge pixel.
                    .overlay {
                        if session.eyedropperArmed {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    sampleWhiteBalance(at: location, content: content.size)
                                }
                        }
                    }
                    .overlay(alignment: .top) { sideBySideLabel }
                    // The crop frame sits on the CANVAS, so its bounds are
                    // already the image's content rect — in POINTS, from
                    // EditorCanvasGeometry. Nothing here converts to pixels.
                    .overlay {
                        if session.cropMode {
                            CropFrameOverlay(
                                rect: Binding(get: { session.pendingCrop ?? .full },
                                              set: { session.pendingCrop = $0 }),
                                aspect: cropAspect.ratio(portrait: cropPortrait),
                                // Without this the lock is applied to the raw
                                // ratio in NORMALIZED space, and a 1:1 drag on
                                // a 3:2 photo yields a 1.5:1 rect.
                                imageAspect: session.displayAspect,
                                onCommit: {})
                        }
                    }
                    .position(x: content.midX, y: content.midY)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, size in canvasSize = size }
            .gesture(panGesture(canvas: geo.size))
            .simultaneousGesture(magnifyGesture(canvas: geo.size))
            .onHover { hovering in
                isHoveringCanvas = hovering
                syncHoverCursor()
            }
            .onChange(of: session.canvasZoom) { _, _ in syncHoverCursor() }
            .overlay(alignment: .topLeading) { targetReadout }
            .onContinuousHover { phase in
                handleTargetHover(phase, content: content)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The width ÷ height the canvas view takes, from the image being shown.
    var contentAspect: CGFloat {
        EditorCanvasGeometry.contentAspect(
            imageSize: session.canvasImage?.extent.size ?? CGSize(width: 3, height: 2),
            sideBySide: session.compareMode == .sideBySide)
    }

    /// The canvas. Was a split that could pair the canvas with a pinned
    /// "reference photo"; that feature is gone (2026-08-02) — the only way to
    /// arm it was a right-click in a different view, so in the editor it read
    /// as a permanently-disabled control. Before/after and Side by Side cover
    /// comparison, and Find Similar Photos covers "show me ones like this".
    var canvasRegion: some View { canvas }

    /// The floating EV/zone readout shown while targeting on the canvas.
    @ViewBuilder
    var targetReadout: some View {
        if session.toneZoneTargeting, let ev = hoveredEV, let zone = session.hoveredZone {
            Text(String(format: "%.1f EV · ", ev) + String(localized: "Zone \(zone + 1)"))
                .font(theme.valueFont)
                .foregroundStyle(theme.textPrimary)
                .padding(theme.spacingS)
                .background(theme.panelFill, in: RoundedRectangle(cornerRadius: theme.radius))
                .padding(theme.spacingM)
        }
    }

    func compareChip(_ text: String) -> some View {
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
    var wipeCompareImage: CIImage? {
        switch session.compareMode {
        case .off: return nil
        case .wipe, .sideBySide: return wipeImage ?? session.originalImage
        }
    }

    var wipeFraction: Double? {
        if case .wipe(let f) = session.compareMode { return f }
        return nil
    }

    @ViewBuilder
    var sideBySideLabel: some View {
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

    // MARK: - Columns

    /// The workspace decides which cards a column holds and in what order. It
    /// used to be two hard-coded @ViewBuilder lists here — `leftPanelContent`
    /// and `rightPanelContent` — so the layout was source code.
    @ViewBuilder
    func columnContent(_ column: EditorColumn) -> some View {
        ForEach(workspace.active.visible(in: column)) { module in
            card(for: module)
        }
    }

    // MARK: - Readouts, target mode, feedback

    /// Statistics cost something, so they run only while a panel is showing
    /// them — the Light card (curve backdrop + zone mass) or Scopes. Collapsing
    /// both stops the pass, which is the point of making the cards collapsible.
    func updateStatsVisibility() {
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
    func buildZoneMaskIfNeeded() async {
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
    func handleTargetHover(_ phase: HoverPhase, content: CGRect) {
        guard session.toneZoneTargeting else { return }
        switch phase {
        case .active(let location):
            NSCursor.crosshair.set()
            // The hover point is in the WINDOW-sized gesture surface; shift it
            // into the content's own coordinates before mapping.
            let local = CGPoint(x: location.x - content.minX, y: location.y - content.minY)
            guard let ev = sampleEV(at: local, content: content.size) else { return }
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

    func sampleEV(at point: CGPoint, content: CGSize) -> Double? {
        guard let map = session.zoneEVMap, map.width > 0, map.height > 0,
              session.canvasImage != nil else { return nil }
        // A division, because the content rect IS the image's rect. This used
        // to rebuild a fit from the FULL window while the renderer fitted into
        // the window minus the panels, so it read the wrong pixel whenever the
        // panels were showing.
        guard let unit = EditorCanvasGeometry.unitPoint(inContentOfSize: content, at: point)
        else { return nil }
        let x = min(max(Int(unit.x * Double(map.width)), 0), map.width - 1)
        let y = min(max(Int(unit.y * Double(map.height)), 0), map.height - 1)
        return Double(map.values[y * map.width + x])
    }

    /// Scroll adjusts the hovered zone while targeting, and is CONSUMED so the
    /// canvas doesn't zoom underneath the gesture.
    func handleTargetScroll(_ event: NSEvent) -> Bool {
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

    func loadFeedback() async {
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
    func sampleWhiteBalance(at location: CGPoint, content: CGSize) {
        session.eyedropperArmed = false
        guard let image = session.originalImage ?? session.canvasImage else { return }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        // `location` is already in the canvas view's own space — the overlay
        // sits ON the canvas, which is the image's rect. Same correction as
        // sampleEV: the old path fitted against the whole window.
        guard let unit = EditorCanvasGeometry.unitPoint(inContentOfSize: content, at: location)
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

}

/// Zebra thresholds. These persist (unlike the toggle) because they are a
/// judgement about what counts as clipped, not a momentary check — and they
/// are the SAME values the Scopes percentages and the stored-stat-free live
/// statistics read.
struct ZebraThresholdsPopover: View {
    @State var high = AppSettings.editorZebraHigh
    @State var low = AppSettings.editorZebraLow

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
