//
//  HeroImageViewer.swift
//  Muse
//
//  The hero image viewer composition (Task 9): ViewerBackdrop +
//  HeroStage + chrome (✕ / zoom pill / Fit) + ViewerInfoColumn +
//  ViewerToast. Opens with a flight from the grid tile, closes with
//  the return flight; arrow keys flip between image-kind files;
//  Delete moves to Trash with an undo toast.
//

import SwiftUI
import AppKit
import ImageIO

struct HeroImageViewer: View {
    @EnvironmentObject var appState: AppState
    let file: FileNode
    /// This viewer was opened by the grid's right-click ▸ Edit — see
    /// `flyingToEditor`. Passed in rather than read from `AppState` in `body`
    /// because it has to be true on the very FIRST frame: the stage's open
    /// flight departs from its own `onAppear`, which SwiftUI runs before this
    /// view's, so a flag set in `onAppear` would arrive after takeoff.
    var openInEditor: Bool = false

    @State private var currentURL: URL
    @State private var details: ViewerFileDetails?
    /// Extra metadata (EXIF / PDF / A/V) for the current file's INFO card.
    @State private var metadata: FileMetadata?
    @State private var naturalSize: CGSize?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var isClosing = false
    @State private var chromeVisible = false
    @State private var toast: ToastData?
    @State private var burnProgress: Double = 0
    @State private var burning = false
    @State private var deleteTask: Task<Void, Never>?
    @State private var viewportSize: CGSize = .zero
    /// After the close flight lands with an undo toast still showing, we keep
    /// only the toast mounted so Undo stays clickable; selectedFile is cleared
    /// once the toast dismisses.
    @State private var lingering = false
    @State private var scrollMonitor: Any?
    @State private var keyMonitor: Any?
    /// Palette computed on open when the DB has none (file not yet analyzed).
    /// The prototype always tints the backdrop and shows color swatches —
    /// that can't wait for an explicit Analyze run.
    @State private var computedPalette: [String] = []
    /// False until the current file's palette is known (DB or quick compute);
    /// the info column shows placeholder swatches meanwhile so the actions
    /// row mounts in its final position.
    @State private var paletteResolved = false
    /// Overlay's frame in SwiftUI .global coords; the scroll monitor uses
    /// minX to ignore scrolls over the sidebar.
    @State private var overlayGlobalFrame: CGRect = .zero
    /// Edit mode swaps the STAGE's content. It deliberately touches nothing
    /// else: the open/close flight, the parting ripple and the backdrop fade
    /// are all untouched by it.
    @State private var editMode = false
    @State private var editSession: EditSession?
    /// Bumped to make the Preview stage re-decode after an edit — see
    /// `HeroStage.editRevision`.
    @State private var editRevision = 0
    /// The saved stack hash the Preview stage's CURRENT pixels were rendered
    /// with, captured when Edit opens.
    ///
    /// Compared against — rather than re-reading the index at exit and calling
    /// any change a change — because the editor AUTOSAVES on a debounce. An
    /// autosave that fired mid-session already wrote the new hash to the index,
    /// so "did the index change while I was in the editor?" answers no on
    /// exactly the sessions where the stage is most stale.
    @State private var renderedStackHash: String?
    /// The editor's photo rect in the overlay's coordinate space, kept live by
    /// `EditorView` so the close flight can depart from exactly where the
    /// picture already is. A box, NOT @State — see `EditorCanvasRectBox`.
    @State private var editorCanvasRect = EditorCanvasRectBox()
    /// This close started in Edit mode. Only used to keep the Preview page's
    /// info column OUT of a flight it was never part of — the editor has no
    /// such column, so mounting one for the 0.34s return would be a panel
    /// sliding in as the photo leaves.
    @State private var closingFromEditor = false
    /// The pixels the Preview stage is showing right now — already decoded and
    /// already rendered through the saved edit stack. Handed to a new
    /// `EditSession` as its opening canvas so Edit doesn't mount empty.
    ///
    /// A reference BOX, not a plain `@State` value, and that is the point: the
    /// stage lands three decode rungs per file (thumbnail → mid → sharp), so a
    /// value here would invalidate this whole view — backdrop, info column,
    /// chrome — three times per open, for data no part of the body reads. Only
    /// `enterEditMode` reads it, at the moment of the click. Mutating the box's
    /// contents changes no SwiftUI state, so nothing re-renders.
    @State private var heroImage = HeroImageBox()
    /// This open is flying STRAIGHT to the editor, and hasn't landed yet.
    ///
    /// While it's true the viewer is not the Preview page at all: the backdrop
    /// is the editor's flat field rather than the photo's wash, the info column
    /// and the Preview | Edit switch never mount, and the stage fits the photo
    /// into the editor's rect (`editorFitBox`) rather than the viewport. It
    /// goes false once `EditorView` is mounted, at which point everything is
    /// the ordinary in-the-editor state.
    @State private var flyingToEditor = false
    /// The editor is MOUNTED but must not be seen yet: it is warming up behind
    /// the photo while that photo is still flying to it. See `EditorView`'s
    /// `panelsHidden` for the measurement that put it there.
    @State private var editorWarming = false

    /// Edit is on screen — which a WARMING editor is not, so the stage stays
    /// visible and keeps flying while the editor builds itself underneath.
    private var editing: Bool { editMode && editSession != nil && !editorWarming }

    /// Read only so the Preview | Edit switch can stay legible over whichever
    /// editor backdrop is set — the editor owns this preference.
    @AppStorage(AppSettings.editorBackdropKey) private var editorBackdropRaw =
        EditorBackdropLevel.default.rawValue

    init(file: FileNode, openInEditor: Bool = false) {
        self.file = file
        self.openInEditor = openInEditor
        _currentURL = State(initialValue: file.url)
        // Seeded here, not in `onAppear`, for the reason given on `openInEditor`
        // — the stage takes off first. Gated on the kind so a request that
        // somehow reaches a file the editor can't open degrades to a normal
        // Preview open rather than a flight to a rect nothing will fill.
        _flyingToEditor = State(initialValue: openInEditor && Self.isEditableKind(file.url))
    }

    /// Where the editor will draw this photo, computed BEFORE the editor
    /// exists.
    ///
    /// The same two functions `EditorView` itself lays the canvas out with, fed
    /// the state the editor mounts in: `stepColumnFit(animated: false)` runs on
    /// its appear, so an emptied column is already emptied on frame one, and
    /// `chromeProgress` starts at 1. Reusing them is the point — a hand-rolled
    /// copy of the panel geometry here would be a second calculation to keep in
    /// step with the first.
    private func editorFitBox(viewport: CGSize) -> CGRect {
        let workspace = EditorWorkspaceStore.shared.active
        let insets = EditorCanvasGeometry.panelInsets(
            leftEmptied: workspace.isEmpty(.left) ? 1 : 0,
            rightEmptied: workspace.isEmpty(.right) ? 1 : 0,
            chromeProgress: 1)
        // NO tracing in here. This is called from `body`, so it runs on every
        // frame of the flight — a `PhaseTrace.mark` here took a lock and queued
        // a file write per frame, and made the very animation it was measuring
        // jagged (owner-reported, 2026-08-04). Instrument the decode rungs
        // instead; they fire three times, not sixty times a second.
        return EditorCanvasGeometry.freeRect(canvas: viewport, insets: insets)
    }

    var body: some View {
        GeometryReader { geo in
            let overlayGlobal = geo.frame(in: .global)
            ZStack {
                if !lingering {
                    if closingFromEditor || flyingToEditor {
                        // The editor's flat field, held for the flight and faded
                        // on the same curve the wash uses.
                        //
                        // The Preview wash has been sitting behind the editor all
                        // along, so simply letting the editor unmount REVEALED it
                        // — a full-strength tint of the photo's dominant colour,
                        // on screen for the frame before the close fade could
                        // start (owner-reported "a flash of the preview
                        // background colour"). No amount of retiming hides that;
                        // the wash has to not be the thing underneath. Keeping
                        // the neutral field means the background the editor had
                        // is the background that fades away.
                        //
                        // The OPEN half (`flyingToEditor`) uses it for the
                        // mirror-image reason: an open heading straight for Edit
                        // must never show the photo's wash, or the editor
                        // arriving would swap the whole background out from
                        // under a photo that has just finished moving.
                        Color(white: EditorBackdropLevel.resolve(editorBackdropRaw).brightness)
                            .ignoresSafeArea()
                            .opacity(isClosing ? 0 : 1)
                            .animation(.easeOut(duration: 0.3), value: isClosing)
                            .accessibilityHidden(true)
                    } else {
                        ViewerBackdrop(hexColor: details?.dominantColor ?? computedPalette.first,
                                       closing: isClosing)
                            // Asymmetric on purpose: the fade-OUT must finish before
                            // the viewer unmounts (0.36s after close starts) — a 0.4s
                            // fade left the material/wash at ~1–2% opacity when the
                            // subtree was removed, and that near-invisible app-wide
                            // layer vanishing in one frame read as a subtle whole-
                            // window flicker on every close.
                            .contentShape(Rectangle())
                            .onTapGesture { startClose() }
                    }

                    // The stage stays MOUNTED while editing, hidden behind the
                    // editor. Unmounting it is what made the return to Preview
                    // replay the whole open flight: a remount fires
                    // `HeroStage.open()`, which takes off from the grid tile's
                    // rect and re-seeds from the 320pt thumbnail before
                    // decoding again — so every Edit → Preview trip flew the
                    // photo in from behind the viewer and landed it soft.
                    // Kept alive, coming back is a no-op: same view, same
                    // decoded image, already at `fitRect`.
                    HeroStage(url: currentURL,
                              sourceFrame: localSourceFrame(overlayGlobal: overlayGlobal,
                                                            viewport: geo.size),
                              viewport: geo.size,
                              burnProgress: burnProgress,
                              onCloseFinished: finishClose,
                              onImageReady: { heroImage.store($1, for: $0) },
                              editRevision: editRevision,
                              closeTakeoff: editorCloseTakeoff,
                              fitBox: flyingToEditor ? editorFitBox(viewport: geo.size) : nil,
                              zoom: $zoom,
                              pan: $pan,
                              isClosing: $isClosing)
                        .opacity(editing ? 0 : 1)
                        // No hover cursor, no pan/pinch from the hidden stage.
                        .allowsHitTesting(!editing)
                        // Opacity 0 hides a view from the eye but NOT from
                        // VoiceOver — an invisible stage left mounted would
                        // still be an element to swipe onto while the editor
                        // is the thing on screen.
                        .accessibilityHidden(editing)

                    // The info column belongs to the Preview page. It is out of
                    // both editor flights for the same reason: mounting it for
                    // the 0.3s the photo is in the air is a panel sliding in
                    // beside a picture on its way somewhere else.
                    if !editing && !closingFromEditor && !flyingToEditor { rightRail }

                    if let editSession, editMode {
                        EditorView(session: editSession,
                                   onClose: closeFromEditor,
                                   onCanvasRect: { editorCanvasRect.rect = $0 },
                                   panelsHidden: editorWarming)
                            // Invisible and inert while warming: what the user
                            // is watching is still the STAGE's photo, and this
                            // view is quietly building the same picture at the
                            // same rect underneath it.
                            .opacity(editorWarming ? 0 : 1)
                            .allowsHitTesting(!editorWarming)
                            .accessibilityHidden(editorWarming)
                    }
                    // Hidden along with the rest of the chrome when Edit's
                    // eye is on: "only the image" has to include this too.
                    if editModeAvailable && !flyingToEditor {
                        if let editSession, editMode {
                            EditChromeGate(session: editSession) { zoomed in
                                editModeToggle(zoomed: zoomed)
                            }
                        } else {
                            editModeToggle(zoomed: zoom > 1.001)
                        }
                    }
                }
                ViewerToast(toast: $toast)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Named so the EDITOR can report where it is drawing the photo in
            // the same space the flight uses — see ViewerGeometry.overlaySpace.
            .coordinateSpace(name: ViewerGeometry.overlaySpace)
            // Delete: the image fades first; then, as it's finishing, the whole
            // page (right-side info + backdrop) fades out behind it, landing
            // back on the grid. Animatable so the curve is sampled every frame.
            .modifier(FadeOutModifier(progress: burnProgress,
                                      fadeStart: 0.5, fadeLength: 0.5))
            .onAppear {
                viewportSize = geo.size
                overlayGlobalFrame = overlayGlobal
            }
            .onChange(of: geo.size) { _, s in viewportSize = s }
            .onChange(of: overlayGlobal) { _, f in overlayGlobalFrame = f }
        }
        .ignoresSafeArea()
        .background {
            // Detach key/click capture during the delete-linger state so the
            // grid stays fully interactive under the undo toast.
            if !lingering {
                KeyCaptureView(onLeft: { flip(-1) },
                               onRight: { flip(1) },
                               onReturn: {},
                               onKey: { keyCode in
                                   // J toggles clipping zebras — Lightroom's
                                   // convention, and only while editing.
                                   guard editMode, keyCode == 38,
                                         let session = editSession else { return false }
                                   session.zebrasOn.toggle()
                                   return true
                               })
            }
        }
        .onAppear {
            installScrollMonitor()
            installKeyMonitor()
            armAutoEdit()
            // The wash is at full strength from frame one — there is no
            // fade-in state to set here any more.
            //
            // Opening used to wait (up to 0.2s) for the tint to resolve, on the
            // theory that fading in neutral and then morphing was the reported
            // open flicker. Instrumentation disproved that — the backdrop's
            // first render already carries the final tint — and A/B testing
            // showed the real cause was animating opacity on `.ultraThinMaterial`,
            // which re-composites the blur every frame. So the wait bought
            // nothing and only delayed the open, and the opacity fade-in was
            // removed outright (ViewerBackdrop now animates only its tint, and
            // its `closing` flag drives the one fade that remains).
            // …but NOT while flying to the editor. The chrome this fades in is
            // the Preview page's, and the editor brings its own; raising it
            // here would put the Preview | Edit switch on screen for a third of
            // a second in the middle of a flight that never visits Preview.
            // `armAutoEdit` raises it on the far side instead.
            if !flyingToEditor {
                withAnimation(.easeOut(duration: 0.4).delay(0.15)) { chromeVisible = true }
            }
        }
        .onDisappear {
            removeScrollMonitor()
            removeKeyMonitor()
            appState.viewerClosing = false
            appState.viewerDismissing = false
            deleteTask?.cancel()
            if burning {
                // Unmounted mid-burn (sidebar navigation, window close):
                // finish the user's delete through the coordinator so the
                // Undo toast survives via GridToastHost.
                let url = currentURL
                let node = appState.currentFiles.first { $0.url == url }
                let appState = self.appState
                Task { @MainActor in
                    do {
                        let ticket = try await TrashManager.trash(url)
                        appState.currentFiles.removeAll { $0.url == url }
                        // The grid renders activeCollectionFiles while a collection
                        // is open — drop the tile there too or it ghosts back on
                        // close and rides into Save-to / Share Drive Link (both read
                        // visibleFiles), matching completeDelete.
                        appState.dropFromActiveCollection(path: url.standardizedFileURL.path)
                        if appState.selectedFile?.url == url { appState.selectedFile = nil }
                        // Clear the stale selection on the trashed file so an
                        // Undo doesn't restore a tile already wearing the ring.
                        appState.clearSelection()
                        appState.deletion.toast = ToastData(message: String(localized: "Moved to Trash"),
                                                            actionLabel: String(localized: "Undo")) {
                            appState.deletion.restore(ticket: ticket,
                                                      node: node ?? FileNode(url: url))
                        }
                    } catch {
                        appState.deletion.toast = ToastData(message: String(localized: "Couldn't move to Trash"))
                    }
                }
            }
        }
        .onChange(of: appState.viewerClosing) { _, closing in
            guard closing else { return }
            // Consume the trigger IMMEDIATELY.
            //
            // `viewerClosing` is a one-shot request ("please run the close"),
            // not durable state — but it was only cleared later, partway through
            // the flight, in three different places. A `true` that outlived its
            // close could then re-fire against a freshly-mounted viewer, which
            // showed up as Escape closing, reopening, and closing again.
            // Clearing it here makes the trigger edge-only and the close
            // idempotent; `isClosing` remains the real state.
            appState.viewerClosing = false
            guard !isClosing else { return }
            // Edit mode consumes Escape FIRST and returns: one press leaves
            // the editor, a second closes the viewer. The rest of the close
            // sequence never runs for that first press.
            //
            // A WARMING editor is not edit mode as far as the user is concerned
            // — the photo is still in the air — so Escape during the flight has
            // to close the viewer, not "leave" an editor never seen.
            if editMode && !editorWarming {
                // Target mode is a mode INSIDE edit mode, so Escape unwinds it
                // one layer at a time: targeting, then the editor, then the
                // viewer.
                if let session = editSession, session.toneZoneTargeting {
                    session.toneZoneTargeting = false
                    session.hoveredZone = nil
                    return
                }
                exitEditMode()
                return
            }
            if lingering || burnProgress > 0 {
                // Mid-burn or lingering after a delete: never run the return
                // flight on a burned image; Esc just dismisses the toast.
                if lingering {
                    withAnimation(.easeOut(duration: 0.18)) { toast = nil }
                }
            } else {
                startClose()
            }
        }
        .onChange(of: toast?.id) { _, id in
            if lingering && id == nil { reallyFinish() }
        }
        .task(id: currentURL) {
            await loadDetails()
        }
        // Reload tag pills when tags mutate library-wide (e.g. the menu-bar
        // Delete All / Regenerate commands fire while this viewer is open) —
        // .task is keyed on the URL, so it wouldn't otherwise refresh.
        .onChange(of: appState.tagsVersion) { _, _ in
            Task { await loadDetails() }
        }
    }

    // MARK: - Right rail (chrome row + info column, shared zoom backing)

    /// The chrome row rides inside the column's content stack, and the zoom
    /// backing card is that stack's layout-bound background — so the card
    /// resizes in the exact spring the expanders use, no measuring. The
    /// paddings compensate for the card's 12pt inset: on screen everything
    /// sits where it did (chrome at 32, cards 40 from the right edge).
    private var rightRail: some View {
        ViewerInfoColumn(url: currentURL,
                         details: details,
                         fallbackPalette: computedPalette,
                         paletteLoading: !paletteResolved,
                         metadata: metadata,
                         backing: infoBackingColor,
                         backingVisible: zoom > 1.001,
                         refresh: { await loadDetails() },
                         onTagTap: { label in
                             appState.searchQuery = label
                             Task { await appState.runSearch(label) }
                             startClose()
                         },
                         onCollectionTap: { id in
                             appState.setActiveCollection(id)
                             startClose()
                         },
                         onOpenInFinder: {
                             NSWorkspace.shared.activateFileViewerSelecting([currentURL])
                         },
                         onDelete: deleteCurrent,
                         toast: $toast,
                         chrome: { chromeRow })
            // Catch taps in the gaps so they don't dismiss.
            .contentShape(Rectangle())
            .onTapGesture {}
            .padding(.top, 20)
            .padding(.bottom, 28)
            .padding(.trailing, ViewerGeometry.columnMargin - 12)
            // No explicit cursor handling needed here: HeroStage's image only
            // PUSHES the open-hand cursor while its own onHover reports
            // true, and pops it the instant the pointer moves onto this
            // column (SwiftUI's onHover correctly yields to the front-most
            // hit-testable view at a point) — leaving the system default
            // arrow, which is exactly what this column wants.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible && !isClosing)
    }

    /// Dark card color behind the info column while zoomed: the image's
    /// dominant color darkened well past the backdrop's 0.55 wash, so the
    /// white text stays readable but the card still "belongs" to the image.
    private var infoBackingColor: Color {
        guard let hex = details?.dominantColor ?? computedPalette.first,
              let (r, g, b) = NamedColor.parse(hex) else {
            return Color(red: 0.14, green: 0.14, blue: 0.15)
        }
        let k = 0.32
        return Color(red: r * k, green: g * k, blue: b * k)
    }

    // MARK: - Chrome (✕ + zoom pill + Fit)

    private var chromeRow: some View {
        HStack(spacing: 8) {
            zoomPill
            if abs(zoom - 1) > 0.001 { fitButton }
            Spacer()
            ShareButton(url: currentURL)
            if abs(zoom - 1) <= 0.001 { closeButton }
        }
        .frame(width: ViewerGeometry.columnWidth)
    }

    private var zoomPill: some View {
        HStack(spacing: 0) {
            ChromePillButton(systemName: "minus",
                             disabled: zoom <= ViewerGeometry.minZoom + 0.001) {
                setZoom(zoom / 1.25, animated: true)
            }
            Text(zoomReadout)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .frame(minWidth: 38)
            ChromePillButton(systemName: "plus",
                             disabled: zoom >= ViewerGeometry.maxZoom - 0.001) {
                setZoom(zoom * 1.25, animated: true)
            }
        }
        .frame(height: 38)
        // Prototype chrome is white-glass: rgba(255,255,255,.10) at rest.
        .background(Capsule(style: .continuous).fill(.white.opacity(0.10)))
        // Segment hover fills are square — keep them inside the capsule ends.
        .clipShape(Capsule(style: .continuous))
    }

    private var fitButton: some View {
        ChromeTextButton(label: String(localized: "Fit")) {
            withAnimation(.easeOut(duration: 0.2)) { zoom = 1; pan = .zero }
        }
    }

    private var closeButton: some View {
        ChromeCircleButton(systemName: "xmark") { startClose() }
    }

    private var zoomReadout: String {
        guard abs(zoom - 1) > 0.001 else { return String(localized: "Fit") }
        if let n = naturalSize, n.width > 0 {
            let fitScale = currentFitRect.width / n.width
            return "\(Int(zoom * fitScale * 100))%"
        }
        return "\(Int(zoom * 100))%"
    }

    // MARK: - Geometry

    private var currentFitRect: CGRect {
        ViewerGeometry.fitRect(imageSize: naturalSize ?? CGSize(width: 1600, height: 1200),
                               viewport: viewportSize)
    }

    /// tileFrames are global (window) coords; the overlay may not start at the
    /// window origin (sidebar / titlebar), so convert via the overlay's own
    /// global frame. Fallback: a centered tile-sized rect.
    private func localSourceFrame(overlayGlobal: CGRect, viewport: CGSize) -> CGRect {
        if let f = appState.tileFrames[currentURL.path] {
            return f.offsetBy(dx: -overlayGlobal.minX, dy: -overlayGlobal.minY)
        }
        let side: CGFloat = 160
        return CGRect(x: (viewport.width - side) / 2,
                      y: (viewport.height - side) / 2,
                      width: side, height: side)
    }

    private func setZoom(_ z: CGFloat, animated: Bool = false) {
        let nz = ViewerGeometry.clampZoom(z)
        let fitted = currentFitRect.size
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                zoom = nz
                pan = ViewerGeometry.clampPan(pan, fittedSize: fitted, zoom: nz)
            }
        } else {
            zoom = nz
            pan = ViewerGeometry.clampPan(pan, fittedSize: fitted, zoom: nz)
        }
    }

    // MARK: - Arrow-key flipping

    private func flip(_ delta: Int) {
        // Arrow keys are INERT in Edit mode: they'd swap the file out from
        // under an in-flight edit, and the arrow keys are wanted for nudging
        // values there anyway.
        guard !editMode else { return }
        guard !isClosing, !lingering, !burning, burnProgress <= 0 else { return }
        let images = appState.visibleFiles.filter { isImageKind($0.kind) }
        guard !images.isEmpty,
              let idx = images.firstIndex(where: { $0.url == currentURL }) else { return }
        let next = images[(idx + delta + images.count) % images.count]
        guard next.url != currentURL else { return }
        computedPalette = []
        paletteResolved = false
        currentURL = next.url
    }

    private func isImageKind(_ kind: AssetKind) -> Bool {
        kind == .image || kind == .raw || kind == .psd
    }

    // MARK: - Edit mode

    /// Path A (in-app editing) is `.image` and `.raw` ONLY. `.psd` is
    /// excluded: what Muse can decode is its flat composite, which is a
    /// PREVIEW of a layered document — editing that and writing it back would
    /// discard the layers. Editing a PSD is Edit-a-Copy's job.
    private var editModeAvailable: Bool {
        guard !isClosing, !burning, burnProgress <= 0, !lingering else { return false }
        return Self.isEditableKind(currentURL)
    }

    /// The KIND half of `editModeAvailable`, without the viewer-state half.
    /// Exposed so the grid's right-click ▸ Edit offers the item on exactly the
    /// files the editor will actually open — one rule, two call sites, rather
    /// than a second copy of the image/RAW list that can drift from this one.
    static func isEditableKind(_ url: URL) -> Bool {
        let kind = AssetKind.detect(at: url)
        return kind == .image || kind == .raw
    }

    /// Sized and coloured as ONE MORE piece of the same chrome family as the
    /// zoom pill and Fit: 38pt tall, white-glass, 11pt medium type. It sits at
    /// ViewerGeometry.chromeTop, so the Preview | Edit switch is on exactly the
    /// same line as Fit / ✕ across the viewer.
    /// The switch floats over whatever is behind it. In Preview that's the
    /// image's dark wash, so it's the same white glass as the zoom pill. In
    /// EDIT it's the user's chosen backdrop — white through black — and a white
    /// glass pill with white type on a white backdrop is invisible. So in edit
    /// mode it takes the panels' resolved AA ink, exactly like the cards do.
    private var toggleInk: PanelContrast.Ink? {
        guard editMode else { return nil }
        return PanelContrast.resolve(
            backdrop: EditorBackdropLevel.resolve(editorBackdropRaw).brightness)
    }

    private func editModeToggle(zoomed: Bool) -> some View {
        HStack(spacing: 0) {
            segment(String(localized: "Preview"), active: !editMode) {
                if editMode { exitEditMode() }
            }
            segment(String(localized: "Edit"), active: editMode) {
                if !editMode { enterEditMode() }
            }
        }
        .frame(height: 38)
        // Translucent glass over a FITTED photo is fine — the backdrop behind
        // it is a wash. Over a ZOOMED one it isn't: the picture runs right
        // under the switch and the labels disappear into it. Same answer the
        // panels use, and the Preview column has always used: bring up a solid
        // backing while zoomed.
        .background(Capsule(style: .continuous).fill(
            zoomed ? (toggleInk?.backing ?? Color(red: 0.14, green: 0.14, blue: 0.15))
                        .opacity(0.94)
                   : (toggleInk?.cardFill ?? .white.opacity(0.10))))
        .clipShape(Capsule(style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, ViewerGeometry.chromeTop)
        .opacity(chromeVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: chromeVisible)
        .allowsHitTesting(chromeVisible && !isClosing)
    }

    private func segment(_ title: String, active: Bool, action: @escaping () -> Void)
    -> some View {
        // Both the type and the selected segment's fill come from the resolved
        // ink in edit mode; the fill is built from the VEIL, so selecting a
        // segment can't pull the surface back under its own label.
        let base = toggleInk?.baseColor ?? .white
        let inactive = toggleInk?.secondaryOpacity ?? 0.7
        return Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(base.opacity(active ? 1.0 : inactive))
                .padding(.horizontal, 14)
                .frame(height: 38)
                .contentShape(Rectangle())
                .background {
                    if active {
                        Capsule(style: .continuous)
                            .fill(toggleInk?.raisedFill(0.24) ?? Color.white.opacity(0.24))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    /// Honour a grid right-click ▸ Edit, if this open is one.
    ///
    /// The request is consumed unconditionally: it is a one-shot edge ("open
    /// THAT file in Edit"), not durable state, and a `true` left lying around
    /// would arm the next viewer the user opened by ordinary double-click.
    private func armAutoEdit() {
        // Consumed unconditionally: it is a one-shot edge ("open THAT file in
        // Edit"), not durable state, and a value left lying around would arm
        // the next viewer the user opened by ordinary double-click. The FLIGHT
        // is already running off `flyingToEditor`, seeded in `init` — this only
        // clears the request and schedules the landing.
        appState.openInEditor = nil
        guard flyingToEditor else { return }
        // Build the editor NOW, hidden, while the photo flies. Everything
        // expensive about arriving — the Metal view, the session, the first
        // proxy render — then happens during the 0.3s of flight instead of in
        // the frame it ends, which is where a measured 69 ms stall used to sit.
        editorWarming = true
        enterEditMode()
        // And reveal it when the flight lands.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(HeroFlightMotion.openDuration))
            revealEditor()
        }
    }

    /// The flight has landed: show the editor that has been warming behind it.
    ///
    /// Nothing expensive happens here by design — the picture is already drawn,
    /// at the same rect, by a view that has been alive for 300 ms. All that
    /// changes is which of the two is visible, plus the panels sliding in.
    private func revealEditor() {
        guard flyingToEditor else { return }
        // The viewer may have LEFT during the flight — Escape closes it, Delete
        // burns it, and both are reachable in those 300 ms because the warming
        // editor takes no input. Revealing then would put a whole editor page on
        // top of a photo already flying home or fading out. Drop it instead: the
        // session is untouched (nothing can have edited it), so there is nothing
        // to save and no state to unwind.
        guard !isClosing, !burning, burnProgress <= 0, !lingering else {
            // `flyingToEditor` deliberately STAYS true here. It is what keeps
            // `fitBox` alive, and clearing it mid-close would re-fit the stage
            // to the viewport un-animated — teleporting the photo out of its
            // own close flight. It also keeps the flat editor backdrop, which
            // is the field this close is fading out of.
            editorWarming = false
            editMode = false
            editSession = nil
            return
        }
        flyingToEditor = false
        editorWarming = false
        // The Preview | Edit switch is the editor's now, so it can come up.
        withAnimation(.easeOut(duration: 0.2)) { chromeVisible = true }
    }

    private func enterEditMode() {
        let url = currentURL
        let isRaw = AssetKind.detect(at: url) == .raw
        // What the stage behind the editor is currently SHOWING. Nothing else
        // writes this file's stack while Preview is up, so the index's value
        // now is the value those pixels were rendered with.
        renderedStackHash = EditStackIndex.stackHash(for: url)
        Task {
            let stack = await EditStore.shared.stack(for: url)
            guard currentURL == url else { return }
            let session = EditSession(url: url, stack: stack, isRaw: isRaw)
            // Before the flip, not after: the editor's first frame then already
            // has the photo. Without it the canvas mounts with `canvasImage ==
            // nil`, so the page is empty until layout settles, a 120 ms
            // debounce elapses and a proxy decode + full stack render land —
            // the photo vanishing and then popping back in, which is what the
            // switch to Edit looked like. It is also the same PIXELS, rendered
            // through the same saved stack, so the proxy that replaces it a
            // moment later is an invisible swap.
            session.seedCanvas(with: heroImage.image(for: url))
            editSession = session
            // A CUT, not a cross-fade. The two pages fit the photo into
            // different rects (Preview to the whole viewport, Edit to the free
            // space between the panels), so fading one into the other now that
            // BOTH carry the image would dissolve two offset copies of the same
            // photo through each other.
            editMode = true
        }
    }

    /// The box the editor is drawing the photo in, already in this overlay's
    /// coordinates (`EditorView` converts through `ViewerGeometry.overlaySpace`).
    /// Nil unless a close from Edit is actually in flight, so the normal Preview
    /// close is untouched by any of this.
    private var editorCloseTakeoff: CGRect? {
        let box = editorCanvasRect.rect
        guard closingFromEditor, box.width > 1 else { return nil }
        return box
    }

    /// Closing the viewer from EDIT mode: the photo flies home from where the
    /// EDITOR had it.
    ///
    /// This was an instant cut from 2026-08-02 until 2026-08-03, after four
    /// animated versions were built and rejected. Three of those four are still
    /// dead ends and must not be retried:
    ///
    ///  * Cross-fade the whole surface: jagged, because the canvas is an
    ///    MTKView and animating opacity over it re-composites Metal every frame
    ///    — the same trap as the material fade documented above.
    ///  * Fly a COPY of the photo over the still-mounted editor.
    ///  * Mount the stage for the return leg only, over the editor's grey.
    ///
    /// The fourth — leave the editor, then run the normal close — was rejected
    /// because "the stage plays its OPEN flight from the tile before shrinking
    /// back". That was true of a stage that got UNMOUNTED while editing, since
    /// a remount fires `HeroStage.open()`. It hasn't been true since 03462ff
    /// kept the stage mounted, so this is that version, made to work:
    ///
    ///  1. The stage is already alive, holding this photo, and (since 7b643ec)
    ///     holding the EDITED pixels.
    ///  2. `closeTakeoff` moves it to where the editor has the picture, one
    ///     runloop turn before the flight starts. Preview fits the photo beside
    ///     one info column and Edit fits it between two panels, so without this
    ///     the reveal frame would jump the photo bigger and ~140pt sideways.
    ///  3. The normal close then runs — same curve, same landing, and the grid
    ///     gets its staggered converge back instead of the cut's hard snap.
    private func closeFromEditor() {
        guard !isClosing else { return }
        // Save first: leaving is the moment work has to be safe, and the
        // session is about to be dropped.
        if let session = editSession { Task { await session.save() } }
        // Before the editor goes: the Preview | Edit switch and the chrome row
        // must not be on screen for the frame between the two pages.
        chromeVisible = false
        // The stage applies `zoom`/`pan` INSIDE the flight transform
        // (`.scaleEffect(zoom)` under `FlightEffect`), so a Preview zoom left
        // over from before the trip into Edit would multiply the takeoff rect
        // and the photo would leap to zoom× the editor's size at the cut. Edit
        // keeps its own zoom — which is already baked into the rect the editor
        // reports — so Preview's has to be neutral here, un-animated and before
        // the seed. `exitEditMode` resets these for the same reason.
        zoom = 1
        pan = .zero
        closingFromEditor = true
        // Reveals the stage — which is showing this photo, at Preview's fitted
        // rect. It is on screen for exactly one turn before `closeTakeoff`
        // lands, and nothing paints in between.
        editMode = false
        editSession = nil
        Task { @MainActor in
            // One frame, so the stage RENDERS at the takeoff rect. SwiftUI
            // animates from the last presented value, so starting the flight in
            // the same turn would interpolate from `fitRect` and throw the
            // takeoff away — the jump this exists to remove.
            try? await Task.sleep(for: .milliseconds(16))
            guard !isClosing else { return }
            startClose()
        }
    }

    private func exitEditMode() {
        let session = editSession
        // Preview comes back FITTED. The two modes keep their own zoom, and a
        // trip through the editor leaving the Preview stage silently zoomed —
        // whatever set it — reads as the editor having resized the photo.
        zoom = 1
        pan = .zero
        // Instant, for the same reason entering is: the stage underneath is
        // still mounted and still showing this photo at `fitRect`, so revealing
        // it is a single frame with nothing to animate.
        editMode = false
        editSession = nil
        // Save on exit as well as on the debounce: leaving the editor is the
        // moment a user expects their work to be safe, and the pending
        // autosave may not have fired yet.
        //
        // The re-decode is bumped AFTER the save resolves, not beside it: the
        // stage re-renders from `EditStackIndex`, so bumping first would
        // re-render the stack the editor had just replaced — the same stale
        // frame, at the cost of a full decode.
        if let session {
            let url = currentURL
            let wasRendered = renderedStackHash
            Task {
                await session.save()
                let saved = EditStackIndex.stackHash(for: url)
                // Only when the pixels are actually wrong. An open-and-leave
                // (or an edit undone back to where it started) would otherwise
                // pay a full-resolution decode — ~600 ms on a 115 MP file — to
                // replace the image with an identical one.
                guard saved != wasRendered, url == currentURL else { return }
                renderedStackHash = saved
                editRevision += 1
            }
        }
    }

    // MARK: - Close flight

    private func startClose() {
        guard !isClosing, !burning, burnProgress <= 0 else { return }
        // Drop the grid selection now, while the tile is still hidden behind the
        // flight. Its 0.15s deselect animation finishes invisibly during the
        // 0.34s return flight, so the tile reveals at normal size (no shrink,
        // no ring) instead of flashing its selected state on landing. Also
        // satisfies "closing with Esc leaves nothing selected."
        appState.clearSelection()
        withAnimation(.easeOut(duration: 0.12)) { chromeVisible = false }
        // Bring the toolbar back now so it returns with the flight (the "never
        // gone" feel) rather than popping in after. The Escape path sets the
        // same flag up front (in ContentView) so both close paths return the nav
        // identically. (Accepts the slight search-bar shadow flash as the trade
        // for a consistent, instant return — see the 2026-06-18 session.)
        // NOT inside `withAnimation`. `viewerDismissing` is @Published on the
        // monolithic AppState, so writing it re-evaluates the whole shell —
        // sidebar rows, every mounted grid tile, the tag chips. Doing that
        // inside a global animation transaction makes SwiftUI build animated
        // transitions for all of it in one synchronous block: profiling the
        // running app measured **282 ms of blocked main thread inside this one
        // setter**, right in the middle of the return flight. That is the
        // owner-reported close stall — the image freezes part-shrunk with the
        // backdrop still up, then jumps the rest of the way. On the largest
        // files the block swallowed the whole flight, which read as "it closes
        // instantly with no animation".
        //
        // Nothing needed the transaction. Both consumers animate on their own:
        // the toolbar returns via ToolbarFade (an AppKit alpha fade driven by
        // an .onChange in ContentView), and the grid tile's reveal is a
        // value-scoped `.animation(_:value:)` in GridView. Don't re-wrap it.
        appState.viewerDismissing = true
        isClosing = true
    }

    private func finishClose() {
        // Keep the undo toast alive past the flight; everything else unmounts.
        if toast != nil && toast?.action != nil {
            lingering = true
        } else {
            reallyFinish()
        }
    }

    private func reallyFinish() {
        appState.viewerClosing = false
        appState.selectedFile = nil
        appState.viewerDismissing = false
    }

    // MARK: - Delete / undo

    private func deleteCurrent() {
        guard !burning, !isClosing else { return }
        burning = true
        let url = currentURL
        let node = appState.currentFiles.first { $0.url == url }
        // Everything stays put — the ripple plays over the full page; the
        // whole viewer fades out on the tail (see deleteFade), not the chrome
        // up front.
        withAnimation(.easeInOut(duration: 0.8)) { burnProgress = 1 }
        deleteTask = Task {
            // Wait for the image + page fade to finish before returning to grid.
            try? await Task.sleep(nanoseconds: 850_000_000)
            guard !Task.isCancelled else { return }
            await completeDelete(url: url, node: node)
        }
    }

    private func completeDelete(url: URL, node: FileNode?) async {
        do {
            let ticket = try await TrashManager.trash(url)
            burning = false
            // The burn has fully finished; now CLOSE back to the grid we came
            // from (main / tag / collection) — never linger on the burned frame
            // and never advance to the next image. The Undo toast is handed to
            // the always-present GridToastHost so it stays clickable over the
            // grid, and selectedFile = nil unmounts the viewer.
            withAnimation(.easeIn(duration: 0.2)) {
                appState.currentFiles.removeAll { $0.url == url }
                // The grid renders activeCollectionFiles while a collection is
                // open — drop the tile there too or it ghosts back on close.
                appState.dropFromActiveCollection(path: url.standardizedFileURL.path)
            }
            appState.deletion.toast = ToastData(message: String(localized: "Moved to Trash"),
                                                actionLabel: String(localized: "Undo")) {
                appState.deletion.restore(ticket: ticket,
                                          node: node ?? FileNode(url: url))
            }
            appState.viewerClosing = false
            appState.viewerDismissing = false
            appState.selectedFile = nil
            // Drop the grid selection too: it pointed at the just-trashed file.
            // Without this the stale path survives in `selectedFiles`, so an
            // Undo would restore the tile already wearing the selection ring —
            // the same stray-selection flash the close fix removes for Esc.
            appState.clearSelection()
        } catch {
            withAnimation(.easeOut(duration: 0.18)) {
                toast = ToastData(message: String(localized: "Couldn't move to Trash"))
                burnProgress = 0
                burning = false
                chromeVisible = true
            }
            appState.viewerClosing = false
        }
    }

    // MARK: - Details loading

    private func loadDetails() async {
        let url = currentURL
        // The quick-palette fallback is started LAZILY, only if the DB turns out
        // to have no analyzed palette.
        //
        // It used to be kicked off here, concurrently with the DB read, so
        // swatches would land before the chrome fade-in finished. That is the
        // right instinct for an unanalyzed file, but it made every ANALYZED file
        // pay a decode whose result is thrown away — and `quickPalette` asks for
        // a 48px thumbnail, which for formats ImageIO can't stream-downsample
        // still materializes the FULL raster. On a 659 MB scan that is 266 ms and
        // ~1 GB, running concurrently with the hero image's own 532 ms full
        // decode of the same file: two giant rasters at once, for a tint that
        // gets discarded.
        //
        // The DB read is local SQLite (sub-millisecond), so deferring the decode
        // behind it costs an unanalyzed file nothing measurable and saves an
        // analyzed one the entire decode.
        // Everything the info column needs, fetched CONCURRENTLY.
        //
        // These used to run in sequence — DB read, then EXIF/metadata, then
        // pixel size — so the column filled in visibly staggered steps and the
        // whole thing took the SUM of three independent I/O waits. They share
        // no data; there is no reason to serialise them.
        let kind = AssetKind.detect(at: url)
        async let detailsTask: ViewerFileDetails? = {
            guard let queue = Database.shared.dbQueue else { return nil }
            return try? await ViewerFileDetails.load(queue: queue, path: url.path)
        }()
        async let metaTask = FileMetadata.load(url: url, kind: kind)
        async let headerSizeTask = Task.detached(priority: .userInitiated) {
            Self.imagePixelSize(at: url)
        }.value

        let loaded = await detailsTask
        guard url == currentURL else { return }
        details = loaded
        // "Why it looks this way" is no longer loaded here — it belongs to the
        // EDIT panel now, which does its own (identical, precomputed-column)
        // read when a session opens. The Preview page never pays for it.
        // Extra metadata for the INFO card (off-main, no DB). Derive the kind
        // from the live URL (navigation changes currentURL, not `file`). Like
        // `details`/palette above, we deliberately DON'T clear `metadata` first:
        // letting the prior card linger until the new load resolves avoids a
        // disappear/reappear flash on fast navigation.
        // Pixel size first: it drives layout, so settling it before the text
        // arrives stops the column resizing under content that's already shown.
        let headerSize = await headerSizeTask
        naturalSize = loaded?.pixelSize ?? headerSize
        let meta = await metaTask
        if url == currentURL { metadata = meta }
        // No analysis data yet → derive backdrop tint + swatches right now.
        if let palette = loaded?.palette, !palette.isEmpty {
            paletteResolved = true
        } else {
            let pal = await HeroPalette.quickPalette(at: url)
            if url == currentURL {
                withAnimation(.easeOut(duration: 0.25)) {
                    computedPalette = pal
                    paletteResolved = true
                }
            }
        }
    }

    nonisolated private static func imagePixelSize(at url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: w, height: h)
    }

    // MARK: - Scroll-wheel zoom (stage area only)

    /// Local monitor active while the viewer is mounted. Scrolls over the
    /// info column pass through (column keeps scrolling normally); scrolls
    /// over the stage zoom and are consumed.
    /// ESCAPE, taken before SwiftUI sees it.
    ///
    /// The shell's `.keyboardShortcut(.cancelAction)` button wins over an
    /// in-view key handler, so Escape was still routing through AppState's
    /// `viewerClosing` — a @Published write that re-evaluates the whole shell
    /// before the close begins, which is why it didn't move like ✕ does. A
    /// local keyDown monitor runs ahead of both, so Escape can make the exact
    /// same call the button makes.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, !lingering, !burning, burnProgress <= 0,
                  let window = event.window, window.isKeyWindow,
                  // A card over the viewer owns Escape first.
                  !appState.modalPresented,
                  // So does a workspace reorder. It is a MODE inside the editor
                  // rather than a card, so `modalPresented` does not cover it —
                  // and this monitor runs ahead of SwiftUI, so without this the
                  // shell's `.cancelEditorReorder` branch never got the key and
                  // Escape closed the whole viewer, discarding the arrangement.
                  // Yielding here (rather than cancelling from inside the
                  // viewer) keeps ONE place deciding what Escape peels first:
                  // EscapeResolver.
                  !EditorWorkspaceStore.shared.reorderMode else { return event }
            if editMode { closeFromEditor() } else { startClose() }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Edit mode has its own scrollable panels on BOTH sides. This
            // monitor claims everything left of the Preview column's x, which
            // silently swallowed every scroll over the editor's left panel —
            // the right one worked only because it sits past that line.
            guard !editMode else { return event }
            guard !isClosing, !lingering, !burning, burnProgress <= 0,
                  let window = event.window, window.isKeyWindow else { return event }
            let width = window.contentView?.bounds.width ?? window.frame.width
            let columnLeft = width - ViewerGeometry.columnWidth - ViewerGeometry.columnMargin
            // locationInWindow is bottom-left origin, but X is unaffected by the
            // Y-flip — comparing against the overlay's global minX keeps scrolls
            // over the sidebar from zooming.
            guard event.locationInWindow.x >= overlayGlobalFrame.minX,
                  event.locationInWindow.x < columnLeft else { return event }
            let dy = event.scrollingDeltaY
            guard dy != 0 else { return event }
            setZoom(zoom * (dy > 0 ? 1.08 : 0.93))
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let m = scrollMonitor {
            NSEvent.removeMonitor(m)
            scrollMonitor = nil
        }
    }
}

/// Holds the hero stage's latest decode without publishing it.
///
/// See the `heroImage` note in `HeroImageViewer`: this exists so landing a
/// decode rung doesn't re-render the viewer, and so the image can never be
/// read back for a file it doesn't belong to.
/// Not `private`: the file-match guard is the whole correctness of the seed,
/// and a test has to be able to reach it.
final class HeroImageBox {
    private var url: URL?
    private var latest: NSImage?

    func store(_ image: NSImage, for url: URL) {
        self.url = url
        latest = image
    }

    /// The stored image, but only if it is this file's.
    func image(for url: URL) -> NSImage? { self.url == url ? latest : nil }
}

/// Where the editor has the photo, in the hero overlay's coordinate space.
///
/// A reference BOX for the same reason `HeroImageBox` is one, and it matters
/// more here: `EditorView` reports this from an `.onChange` on its content
/// rect, which moves EVERY FRAME of a canvas zoom, a pan, and the hide-UI
/// animation. As `@State` on the hero viewer, each of those frames invalidated
/// the whole hero body — backdrop, stage, editor, chrome — to update a value no
/// part of the body reads until the ✕ is pressed. Mutating a box changes no
/// SwiftUI state, so nothing re-renders; `closingFromEditor` is the @State that
/// does the one invalidation this needs.
final class EditorCanvasRectBox {
    var rect: CGRect = .zero
}

/// Shows its content only while the editor's controls are visible.
///
/// `editSession` is held as plain @State by the hero viewer, which tracks the
/// REFERENCE and not the object's `@Published` properties — so toggling
/// `uiHidden` re-rendered the editor and left the Preview | Edit switch sitting
/// over the photo. This one small view does the observing.
private struct EditChromeGate<Content: View>: View {
    @ObservedObject var session: EditSession
    /// Passed the canvas's zoomed state, which the switch needs to stay legible
    /// once the photo is running underneath it.
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        if !session.uiHidden {
            content(abs(session.canvasZoom - 1) > 0.001)
        }
    }
}
