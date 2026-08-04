import SwiftUI
import AppKit
import ImageIO

/// The flying image: animates from the grid tile rect to the fitted rect and
/// back, then hosts zoom (1–4x) and drag-pan when zoomed.
/// Timings from the approved prototype: open 0.4s gentle ease-out,
/// close 0.34s with a hint of settle.
/// Maps the image (laid out at `home`) onto the animated `rect` with a single
/// transform. One animatable value drives translation AND scale together —
/// animating .position and .scaleEffect separately let the two interpolations
/// drift, which bent the flight path into a visible arc.
private struct FlightEffect: GeometryEffect {
    var rect: CGRect
    var home: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(AnimatablePair(rect.origin.x, rect.origin.y),
                           AnimatablePair(rect.size.width, rect.size.height))
        }
        set {
            rect = CGRect(x: newValue.first.first, y: newValue.first.second,
                          width: newValue.second.first, height: newValue.second.second)
        }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let sx = rect.width / max(1, home.width)
        let sy = rect.height / max(1, home.height)
        let t = CGAffineTransform(translationX: rect.minX - home.minX,
                                  y: rect.minY - home.minY)
            .scaledBy(x: sx, y: sy)
        return ProjectionTransform(t)
    }
}

/// The OPEN flight's curve: a spring with a little overshoot, so the image
/// arrives with a bounce instead of easing flat into place (owner call,
/// 2026-07-29, after the same feel in Atlas). Speed and bounce are separate
/// knobs — see `openDuration` / `openBounce`.
///
/// Only OPEN is a spring. The CLOSE flight keeps its fixed 0.34s timing curve
/// on purpose: the backdrop's 0.3s fade-out and the 0.36s unmount are timed
/// against that number (see the hero open/close durable constraint), and a
/// spring has no duration to time them against.
enum HeroFlightMotion {
    /// `.spring(duration:bounce:)`, NOT `.spring(response:dampingFraction:)`.
    /// The response/damping form has no bounded settle time — response 0.36 at
    /// 0.86 damping still crept for well over half a second, which read as
    /// "super slow opening" while the overshoot was too small to see. This form
    /// separates the two: `duration` is what the flight actually takes, and
    /// `bounce` is the overshoot, tunable without touching the speed.
    static let openDuration: Double = 0.30
    /// 0 = no overshoot, 0.5 = very springy. Raise for more bounce.
    static let openBounce: Double = 0.28

    static var open: Animation {
        .spring(duration: openDuration, bounce: openBounce)
    }

    /// How long the open spring is still visibly settling. A `displayRect`
    /// write inside this window must stay ON the spring — see `settling(since:)`.
    static let openSettleWindow: TimeInterval = 0.40

    /// The curve for a post-decode `displayRect = fitRect` write.
    ///
    /// Load-bearing: every decode step (quick thumb → mid-res → sharp) re-writes
    /// that rect, and a normal image's sharp decode lands ~100–200 ms after the
    /// flight starts — INSIDE the spring. A `withAnimation(.easeOut)` there
    /// REPLACES the running spring with a flat curve, which swallowed the bounce
    /// entirely (owner-reported "when it opens it does not bounce"). Staying on
    /// the spring lets it finish; after the window a plain ease is right, since
    /// by then it's a correction, not the flight.
    static func settling(since openedAt: Date) -> Animation {
        Date().timeIntervalSince(openedAt) < openSettleWindow
            ? open
            : .easeOut(duration: 0.2)
    }
}

/// A rounded rect whose corner radius is pre-divided by the flight's current
/// scale, so the radius the VIEWER sees stays constant while the image flies.
///
/// The clip is applied in the image's own (unscaled) coordinate space and then
/// scaled by `FlightEffect`, so a plain `RoundedRectangle` renders its radius
/// times the flight scale: on close the corners flatten toward square as the
/// image shrinks, and only snap back when the real tile takes over — the
/// owner-reported "closes to 0 radius, then pops to rounded".
///
/// Dividing by the scale cancels that exactly. `scale` is the animatable datum
/// and comes from the SAME `displayRect` that drives `FlightEffect`, so both
/// interpolate on one curve: rendered radius = (radius / scale(t)) × scale(t),
/// constant for every frame. Compensating with a plain animated radius would
/// NOT work — two independently-interpolated values multiply out to a mid-flight
/// bulge (~2× at the halfway point), not a constant.
private struct FlightRoundedRect: Shape {
    /// The radius as it should APPEAR on screen, in points.
    var radius: CGFloat
    /// Current flight scale (rendered size ÷ laid-out size).
    var scale: CGFloat

    var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard radius > 0 else { return Rectangle().path(in: rect) }
        // A tiny scale would blow the compensated radius past a capsule; the
        // cap keeps the shape a rounded rect no matter how small the target.
        let r = min(radius / max(0.0001, scale),
                    min(rect.width, rect.height) / 2)
        return RoundedRectangle(cornerRadius: r, style: .continuous).path(in: rect)
    }
}

/// What the hero decode is a function of: the file, and the revision of the
/// edit stack applied to it. A plain `URL` id could not express the second.
private struct DecodeKey: Equatable {
    let url: URL
    let editRevision: Int
}

struct HeroStage: View {
    let url: URL
    let sourceFrame: CGRect          // tile frame, global coords
    let viewport: CGSize
    var burnProgress: Double = 0
    var onCloseFinished: () -> Void
    /// Every decode rung this stage lands, handed up so the hero viewer can
    /// open the editor on the pixels already on screen instead of on nothing.
    ///
    /// Carries the URL the pixels came from. An arrow-key flip changes the
    /// file before the new decode lands, so an untagged image would let the
    /// editor open on the PREVIOUS photo.
    var onImageReady: ((URL, NSImage) -> Void)? = nil
    /// Bumped by the parent when the file's SAVED edit stack has changed since
    /// this stage last decoded — the only thing that makes the pixels on screen
    /// wrong without the URL changing.
    ///
    /// `loadFullRes` renders the saved stack (see `sharpStack`), and it is
    /// driven by `.task(id:)`. Keyed on the URL alone, leaving the editor could
    /// never re-run it: the file is the same file. That is not theoretical —
    /// the stage is deliberately kept MOUNTED behind the editor so flipping
    /// Preview ↔ Edit is instant, so an edit made in Edit mode was invisible in
    /// Preview until the viewer was closed and reopened (owner-confirmed in the
    /// running app, 2026-08-03). Part of the identity of what to decode, so it
    /// belongs in the task id rather than in an onChange that races it.
    var editRevision: Int = 0
    /// The box the photo occupies on screen RIGHT NOW, when that isn't where
    /// this stage has it — i.e. closing out of Edit mode, where the editor has
    /// been drawing the picture between its two panels while this stage sat
    /// hidden behind it at `fitRect`.
    ///
    /// Set before `isClosing`, and the flight departs from here instead. A box
    /// rather than a rect: the image is FITTED into it (see `takeoffRect`), so
    /// a photo cropped in the editor letterboxes inside the box rather than
    /// stretching to fill a shape its pixels no longer have.
    var closeTakeoff: CGRect? = nil
    /// Fit the photo into THIS box instead of the whole viewport.
    ///
    /// The mirror of `closeTakeoff`, for an open that is not heading to the
    /// Preview page: the grid's right-click ▸ Edit flies the photo from its
    /// tile straight to where the EDITOR will draw it, so the flip into Edit
    /// mode is a cut with the picture already in its final place. Landing at
    /// Preview's rect first and cutting from there showed a page the user never
    /// asked for, and moved the photo twice.
    ///
    /// Cleared once the editor is mounted, which re-fits this (hidden) stage to
    /// the viewport so every later path — leaving Edit, closing, resizing — is
    /// the ordinary case again.
    var fitBox: CGRect? = nil

    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    @Binding var isClosing: Bool     // set true by parent to run the return flight

    /// Same corner radius the grid tile uses, so a photo keeps its shape when
    /// it opens. The layout radius is the point value the FULL-SCREEN image
    /// shows; the flight scales the whole rendered layer, so mid-flight the
    /// rounding scales with it.
    @AppStorage(AppSettings.gridCornerRadiusKey) private var cornerRadiusSetting =
        AppSettings.defaultGridCornerRadius
    private var cornerRadius: CGFloat {
        CGFloat(AppSettings.clampGridCornerRadius(cornerRadiusSetting))
    }

    /// Every render scale applied to the clipped image: the flight's own scale
    /// (what `FlightEffect` derives from the same two rects) times the user's
    /// zoom, since `.scaleEffect(zoom)` sits outside the clip too. Feeds
    /// `FlightRoundedRect` so the corner radius the viewer sees stays put —
    /// through the flight, and when the image is pulled back below Fit.
    private func renderScale(home: CGRect) -> CGFloat {
        let flight = (home.width > 0 && displayRect.width > 0)
            ? displayRect.width / home.width : 1
        return flight * max(0.0001, zoom)
    }

    @State private var displayRect: CGRect = .zero
    /// One mid-flight retarget per close — see the sourceFrame onChange.
    @State private var didRetarget = false
    @State private var image: NSImage?
    @State private var dragStartPan: CGSize? = nil
    /// The zoom a pinch started from — see `magnifyGesture`.
    @State private var magnifyStartZoom: CGFloat?
    @State private var isDraggingPan = false
    /// Plain "is the pointer over the image" — independent of whether we've
    /// actually pushed a cursor for it (see `isHoverPushed`).
    @State private var isHoveringImage = false
    /// Whether `NSCursor.openHand` is CURRENTLY on the push/pop stack for
    /// this hover session. Tracked separately from `isHoveringImage` so
    /// `syncHoverCursor()` can push/pop exactly once per state transition —
    /// mismatched push/pop calls corrupt the stack for the rest of the app.
    @State private var isHoverPushed = false
    @State private var openedAt = Date.distantPast
    /// Fades out across the close flight so the image lands shadowless,
    /// exactly like the grid tile it's about to become.
    @State private var shadowVisible = true

    private var fitRect: CGRect {
        // Same fit rule either way — only the box differs. The header size is
        // preferred over the decoded image for the same reason `sourceRect`
        // prefers it: at flight start nothing has decoded yet, and falling
        // through to the tile's size would fit the photo to the wrong shape.
        if let fitBox, fitBox.width > 1, fitBox.height > 1 {
            return ViewerGeometry.fitWithin(
                imageSize: image?.size ?? headerSize ?? sourceFrame.size, frame: fitBox)
        }
        return ViewerGeometry.fitRect(imageSize: image?.size ?? sourceFrame.size,
                                      viewport: viewport)
    }

    /// Where the tile actually draws the image inside its frame (tiles
    /// letterbox with .fit). Flying to/from THIS rect keeps the handoff
    /// pixel-exact in fixed-aspect grid layouts, where the raw tile rect
    /// would land as a center-crop that re-fits on reveal. Falls back to
    /// the tile rect until the image is known.
    private var sourceRect: CGRect {
        // The image's TRUE pixel aspect, from the file header — never the
        // decoded image, which is nil at flight start.
        //
        // This used to be `image?.size ?? sourceFrame.size`. At the moment the
        // flight begins the image hasn't decoded, so it fell through to
        // `sourceFrame.size`, and fitWithin(frame.size, frame) returns the FRAME
        // ITSELF — i.e. the flight started from the raw tile rect, exactly what
        // the drawn-image-rect rule exists to prevent. A landscape image
        // letterboxes heavily inside a squarer tile, so its real drawn rect is
        // far shorter than the tile: starting from the tile rect made the flight
        // much too short, which read as "almost instant" with a wrong curve.
        // Portrait letterboxes less, so it looked nearer correct — that
        // asymmetry is aspect geometry, not file size.
        //
        // Reads only in-memory state — NEVER the filesystem. See `headerSize`.
        ViewerGeometry.fitWithin(imageSize: headerSize ?? image?.size ?? sourceFrame.size,
                                 frame: sourceFrame)
    }

    /// The file's true pixel size, resolved ONCE per open and held in state.
    ///
    /// This is deliberately not read on demand from `sourceRect`. `sourceRect`
    /// is a computed property, so SwiftUI re-evaluates it on every body pass —
    /// i.e. on every frame of the open and close flights. The header read
    /// underneath it costs ~18 ms on a 659 MB scanner TIFF (measured), and it
    /// was memoized in an `NSCache`, which EVICTS under memory pressure — the
    /// exact state a giant image open puts the app in. An evicted entry during
    /// an animating body meant a fresh 18 ms file open per frame on the main
    /// thread: dropped frames, a mid-flight stall with the backdrop still up,
    /// and on the very largest file the close flight skipping outright. All
    /// three were owner-reported.
    ///
    /// Now: seeded from the never-evicting `ImageHeaderSizeCache` (which the
    /// thumbnail pass has already warmed off-main for every file in the folder,
    /// so the common case is a dictionary hit at open with no I/O at all), and
    /// read only as state from there on.
    @State private var headerSize: CGSize?

    /// Which URL `headerSize` belongs to. A `@State` box, deliberately: an
    /// escaping closure captures a FROZEN copy of this struct, so `self.url`
    /// inside it still reads the file that was open when the read started —
    /// checking it would be vacuous. `@State` reads through a shared box, so
    /// this one reflects the CURRENT file and can actually reject a stale
    /// result (arrow-key flip A→B while A's header read is still in flight
    /// would otherwise give B the aspect of A, and the close flight would land
    /// on the wrong rect).
    @State private var headerSizeURL: URL?

    /// Seed `headerSize`. Takes the warm value synchronously when there is one;
    /// otherwise reads the header off-main and lands it a moment later — the
    /// flight starts from the decoded/tile aspect in that rare case rather than
    /// blocking on I/O.
    private func resolveHeaderSize() {
        let u = url
        headerSizeURL = u
        // EffectiveDimensions, not ImageHeaderSizeCache: this drives the
        // flight's take-off/landing rect, so it must be what the image DRAWS
        // (post-crop), not what the original file measures.
        if let warm = EffectiveDimensions.cached(u) { headerSize = warm; return }
        Task.detached(priority: .userInitiated) {
            guard let size = EffectiveDimensions.resolve(u) else { return }
            await MainActor.run {
                guard headerSizeURL == u else { return }
                headerSize = size
            }
        }
    }


    var body: some View {
        // ZStack, not Group: with `if let image` empty, a Group has no child
        // views, so .onAppear/.task below never fire and the image never loads.
        ZStack {
            if let image {
                // The flight is a pure render transform, never a layout
                // animation: macOS SwiftUI draws a resizable Image at its
                // final laid-out size while a frame animation only
                // interpolates bounds — the bitmap doesn't scale, so the
                // open flight became a wipe-reveal. Laying out at fitRect
                // and animating scale/position scales the pixels with the
                // rect, like the prototype's object-fit:cover stage.
                let base = fitRect
                Image(nsImage: image)
                    .resizable()
                    // The opened photo is the surface HDR is FOR. Paired with
                    // the same modifier on the grid tile so the two match.
                    .allowedDynamicRange(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: base.width, height: base.height)
                    .clipShape(FlightRoundedRect(radius: cornerRadius,
                                                 scale: renderScale(home: base)))
                    // Delete: the image fades out first (front ~60%).
                    .modifier(FadeOutModifier(progress: burnProgress,
                                              fadeStart: 0.0, fadeLength: 0.6))
                    .shadow(color: .black.opacity(shadowVisible ? 0.5 : 0), radius: 40, y: 24)
                    .scaleEffect(zoom)
                    .offset(pan)
                    .modifier(FlightEffect(rect: displayRect, home: base))
                    // Static layout at the fitted rect — the flight itself is
                    // entirely inside FlightEffect's animated transform.
                    .position(x: base.midX, y: base.midY)
                    .gesture(panGesture)
                    // Trackpad pinch, alongside the scroll-wheel zoom.
                    // `simultaneously` rather than `.gesture`: a pinch and a
                    // pan can overlap on a trackpad, and making them exclusive
                    // means whichever SwiftUI recognises first wins and the
                    // other silently never fires.
                    .simultaneousGesture(magnifyGesture)
                    .onHover { hovering in
                        isHoveringImage = hovering
                        syncHoverCursor()
                    }
            }
        }
        .onAppear { open() }
        .onDisappear { resetCursorState() }
        .onChange(of: image) { _, new in if let new { onImageReady?(url, new) } }
        .onChange(of: isClosing) { _, closing in if closing { close() } }
        .onChange(of: closeTakeoff) { _, box in
            // Un-animated, and a runloop turn BEFORE `isClosing` flips (the
            // caller sequences that). Both halves matter: SwiftUI animates from
            // the last value it PRESENTED, so seeding and animating in one pass
            // would interpolate from `fitRect` and ignore this entirely — the
            // photo would jump to the Preview position and only then fly.
            guard let box, box.width > 1, box.height > 1 else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { displayRect = takeoffRect(in: box) }
        }
        .onChange(of: fitBox) { _, box in
            // The box going away means the editor has taken over and this stage
            // is hidden behind it. Re-fit to the viewport NOW and un-animated:
            // `displayRect` is still the editor's rect, and leaving it there
            // would show the photo in the editor's spot the moment Preview came
            // back. Hidden, so there is nothing to animate anyway.
            //
            // Never while closing, for the same reason `loadFullRes`'s writes
            // are guarded: an un-animated `displayRect` write during the return
            // flight jumps the photo out of the motion it is in.
            guard box == nil, !isClosing else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { displayRect = fitRect }
        }
        .onChange(of: zoom) { _, _ in syncHoverCursor() }
        .onChange(of: sourceFrame) { _, newFrame in
            // The toolbar returns as the close flight starts, shifting the
            // grid — retarget mid-flight so we land on the tile's real spot
            // (its drawn-image rect, same fit rule as sourceRect).
            guard isClosing else { return }
            // Only retarget for a REAL move, and only once.
            //
            // The grid relayouts more than once during a close (the toolbar
            // returns, the selection clears), so this fired repeatedly and each
            // fire started a fresh 0.22s animation. A transient frame that
            // computed larger made the image grow BACK mid-close — which reads
            // as the viewer closing, reopening, then closing again.
            //
            // Ignores degenerate frames, ignores sub-pixel churn, and runs at
            // most once per close. Uses the same header-derived aspect as
            // `sourceRect` so the retarget can't disagree with the takeoff.
            guard !didRetarget, newFrame.width > 1, newFrame.height > 1 else { return }
            let retarget = ViewerGeometry.fitWithin(
                imageSize: headerSize ?? image?.size ?? newFrame.size,
                frame: newFrame)
            guard abs(retarget.midX - displayRect.midX) > 1
                    || abs(retarget.midY - displayRect.midY) > 1
                    || abs(retarget.width - displayRect.width) > 1 else { return }
            // A close only ever SHRINKS. `didRetarget` caps this at one fire,
            // but one is enough: if the grid's transient relayout reports a
            // frame larger than where the flight is already heading, animating
            // to it makes the image grow back out — which reads exactly as the
            // viewer closing, reopening, then closing again (owner-reported).
            // A slightly-wrong landing spot is invisible under the tile reveal;
            // a reversal is not. So take the correction only when it keeps the
            // flight moving inward.
            //
            // The one exception is the degenerate target: when the tile had no
            // frame at close start, close() aims at a zero-size point in the
            // viewport centre. There is no inward progress to protect there, and
            // landing on the tile that has since appeared beats vanishing into
            // the middle of the screen — which is what this retarget is for.
            guard displayRect.width <= 1 || retarget.width <= displayRect.width + 1
            else { return }
            didRetarget = true
            withAnimation(.timingCurve(0.3, 1.08, 0.35, 1, duration: 0.22)) {
                displayRect = retarget
            }
        }
        .onChange(of: url) { _, _ in flipTo() }
        .onChange(of: viewport) { _, _ in
            // spec: re-fit live on window resize (but never mid-burn — the
            // shader's size uniform would jump the char pattern)
            guard !isClosing, burnProgress <= 0 else { return }
            if Date().timeIntervalSince(openedAt) < 0.45 {
                // Viewport settled a beat after mount (toolbar relayout):
                // fold the correction into the open curve — a separate
                // easeOut here bends the flight into a visible arc.
                withAnimation(HeroFlightMotion.open) {
                    displayRect = fitRect
                }
            } else {
                // A live window resize is TRACKING, not a flight — write the
                // rect with animation explicitly off.
                //
                // The layout below takes `base = fitRect` directly, so the
                // frame and position snap to the new viewport the instant the
                // window moves, while `FlightEffect` draws `displayRect`
                // RELATIVE to that base. Animating this write therefore left
                // the transform describing the OLD size for the length of the
                // curve: the window and the rest of the UI moved, the photo
                // stayed big, then sprang to catch up — and because a drag
                // emits a resize per frame, each one restarted the curve, so
                // it lagged the whole way and overshot at the end (owner
                // report). Unanimated, base and displayRect stay equal and the
                // photo tracks the edge exactly.
                //
                // `disablesAnimations` rather than a bare assignment: a resize
                // can arrive inside an ambient transaction, and one inherited
                // animation is all it takes to bring the lag back.
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { displayRect = fitRect }
            }
        }
        .task(id: DecodeKey(url: url, editRevision: editRevision)) { await loadFullRes() }
    }

    private func open() {
        openedAt = Date()
        // Must come first: the takeoff rect below is derived from it.
        resolveHeaderSize()
        // Take off from the SAME rect the close lands on. This was
        // `sourceFrame` (the raw tile rect) while close() flies to `sourceRect`
        // (the letterboxed rect the tile actually draws into) — so open and
        // close were not symmetric, and the mismatch is bigger the more the
        // image letterboxes inside its tile. Now that sourceRect is derived
        // from the header aspect it is valid from the first frame, so there is
        // no reason to use anything else.
        displayRect = sourceRect
        // The grid tile's thumbnail is already in memory — start the flight
        // with it immediately. Awaiting QLThumbnailGenerator here added
        // 100–400ms of dead time before the open animation even began.
        // Once the image (and so its aspect) is known, the flight departs
        // from sourceRect — the letterboxed spot the tile draws — so the
        // takeoff is pixel-exact in fixed-aspect layouts too.
        if let quick = Self.quickThumbnail(for: url) {
            image = quick
            displayRect = sourceRect
            withAnimation(HeroFlightMotion.open) {
                displayRect = fitRect
            }
        } else {
            Task {
                image = await ThumbnailCache.shared.thumbnail(
                    for: url, size: CGSize(width: 320, height: 320))
                displayRect = sourceRect
                withAnimation(HeroFlightMotion.open) {
                    displayRect = fitRect
                }
            }
        }
    }

    /// Sync memory-cache peek at the sizes the app already renders.
    private static func quickThumbnail(for url: URL) -> NSImage? {
        ThumbnailCache.shared.cachedThumbnail(for: url, size: CGSize(width: 320, height: 320))
            ?? ThumbnailCache.shared.cachedThumbnail(for: url, size: CGSize(width: 160, height: 160))
    }

    /// This stage's image, fitted into a box another view was drawing it in.
    ///
    /// Uses the DECODED image rather than the header size: after a crop the two
    /// disagree, and the thing being positioned is the picture on screen.
    private func takeoffRect(in box: CGRect) -> CGRect {
        ViewerGeometry.fitWithin(imageSize: image?.size ?? headerSize ?? box.size,
                                 frame: box)
    }

    private func close() {
        resetCursorState()
        didRetarget = false
        // If the tile has no usable frame (virtualized away, or never measured),
        // flying to it collapses the animation into an instant jump. Shrink
        // toward the viewport centre instead so the close still reads as a
        // close.
        let target: CGRect = (sourceRect.width > 1 && sourceRect.height > 1)
            ? sourceRect
            : CGRect(x: viewport.width / 2, y: viewport.height / 2, width: 0, height: 0)
        withAnimation(.timingCurve(0.3, 1.08, 0.35, 1, duration: 0.34)) {
            zoom = 1; pan = .zero
            displayRect = target
            shadowVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            onCloseFinished()
        }
    }

    private func flipTo() {
        resetCursorState()
        // Arrow-key flip to a different file: the old file's aspect must not
        // survive into the new one's close flight.
        headerSize = nil
        resolveHeaderSize()
        zoom = 1; pan = .zero
        // End the open-settle window. A flip is a RE-FIT of a new image in
        // place, not a flight out of a tile, so it must not inherit the open
        // spring's bounce — and without this it inherited it only when the flip
        // landed inside the window, making the same keypress animate two
        // different ways depending on how fast the user pressed it. With
        // `openedAt` reset, every `settling(since:)` below (the flip's own write
        // AND its post-decode write) resolves to the plain ease, which is what
        // a flip did before the spring existed.
        openedAt = .distantPast
        // thumbnail swaps in fast; .task(id: url) handles the full-res load
        if let quick = Self.quickThumbnail(for: url) {
            image = quick
            withAnimation(HeroFlightMotion.settling(since: openedAt)) { displayRect = fitRect }
        } else {
            Task {
                image = await ThumbnailCache.shared.thumbnail(
                    for: url, size: CGSize(width: 320, height: 320))
                withAnimation(HeroFlightMotion.settling(since: openedAt)) { displayRect = fitRect }
            }
        }
    }

    private func loadFullRes() async {
        let u = url
        // Downsampled, pre-decoded bitmap via ImageIO. NSImage(contentsOf:)
        // deferred the full-size decode to first draw on the main thread —
        // a visible hitch mid-flight on large files.
        let maxDim = Int(max(viewport.width, viewport.height) * 2.5)
        let target = min(max(maxDim, 1600), 4096)
        // Progressive: land a mid-res decode FIRST, then upgrade.
        //
        // Measured: the flight runs 340ms, but a 659MB TIFF needs ~590ms to
        // decode at full target — so it landed soft and visibly sharpened ~250ms
        // later. A 1600px pass costs a fraction of that and is already sharper
        // than the 320px grid thumbnail the flight starts with, so the image
        // looks right as it lands and the final swap is imperceptible. Small
        // files decode inside the flight anyway, so this changes nothing for
        // them beyond one extra cheap decode.
        // Cache-only: `.task` runs on the main actor, so this must not do I/O.
        // An unknown size just skips the extra mid-res pass.
        // ImageHeaderSizeCache directly, NOT headerSize/EffectiveDimensions:
        // this gate is about what it costs to DECODE the file, which is a
        // property of the original bytes. A crop shrinks what's drawn, not what
        // ImageIO has to read, so the effective size would understate the cost
        // and skip the mid-res pass on exactly the files that need it.
        if ImageHeaderSizeCache.cached(u)
            .map({ $0.width * $0.height > 40_000_000 }) == true {
            let midStack = EditStackIndex.resolvedStack(for: u)
            let mid = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                      ThumbnailCache.withinDecodeBudget(src) else { return nil }
                // The hero shows the EDIT, at both decode rungs. Only the
                // decode closure changes — every guard, curve and settle
                // window in this function stays exactly as it was.
                if let midStack,
                   let rendered = EditRenderer.render(url: u, stack: midStack, maxPixel: 1600) {
                    return NSImage(cgImage: rendered,
                                   size: NSSize(width: rendered.width, height: rendered.height))
                }
                // Through the HDR seam, so a gain-map HEIC keeps its
                // headroom at BOTH rungs. Decoding the mid rung flat would
                // land a dim photo that brightened a moment later.
                guard let cg = HDRDecode.decode(source: src, maxPixel: 1600)
                else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
            // `!isClosing`: swapping the image mid-close changes `fitRect`,
            // which is the flight's layout `home` — the transform re-bases
            // under the animation and the image jumps. Nothing is gained by
            // sharpening a picture that is shrinking off screen.
            if let mid, u == url, !isClosing,
               image == nil || (image?.size.width ?? 0) < mid.size.width {
                image = mid
            }
        }

        let sharpStack = EditStackIndex.resolvedStack(for: u)
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            // Same decompression-bomb guard as the grid thumbnail path — refuse
            // to decode a header that declares an absurd pixel count (falls
            // through to the QuickLook path below, which downsamples safely).
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                  ThumbnailCache.withinDecodeBudget(src) else { return nil }
            if let sharpStack,
               let rendered = EditRenderer.render(url: u, stack: sharpStack, maxPixel: target) {
                return NSImage(cgImage: rendered,
                               size: NSSize(width: rendered.width, height: rendered.height))
            }
            guard let cg = HDRDecode.decode(source: src, maxPixel: target)
            else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        // The `!isClosing` guard is load-bearing, not defensive.
        //
        // This assignment flies the image back out to the fitted (full-screen)
        // rect. It exists for the normal case, where the decode lands while the
        // viewer is open. But a 115 MP TIFF takes ~600 ms to decode, and a user
        // who opens and immediately presses Escape closes at ~450–600 ms — so on
        // big files the decode routinely landed INSIDE the close flight and
        // animated the shrinking image back to full size, after which the
        // unmount snapped it away. That is the owner-reported "it closes, then
        // reopens, then closes again", and it only ever showed on large files
        // because only those decode slowly enough to land mid-close.
        //
        // Traced in the running app: the state sequence is a clean single
        // close, so the reopen was purely this geometry write. Don't drop the
        // guard from either of the two exits below.
        if let img, u == url, !isClosing {
            image = img
            withAnimation(HeroFlightMotion.settling(since: openedAt)) { displayRect = fitRect }
            return
        }
        if isClosing { return }
        // ImageIO returned nil — the source isn't decodable by it (e.g. a RAW
        // format Apple's camera codec doesn't support). Fall back to the shared
        // thumbnail path, which tries QuickLook's best representation (some
        // formats render there even when ImageIO can't) and otherwise yields the
        // system type icon — anything is better than leaving the viewer blank.
        guard u == url,
              // Quantized to the fixed ladder, NOT the raw viewport-derived
              // target: the cache key includes the size, so a continuous value
              // would mint variants `invalidate` can't enumerate and an edited
              // file would serve this stale image forever (the on-disk PNG
              // outlives launches).
              let fallback = await ThumbnailCache.shared.thumbnail(
                  for: u,
                  size: {
                      let s = ThumbnailCache.heroFallbackSize(forMaxDimension: CGFloat(target))
                      return CGSize(width: s, height: s)
                  }(),
                  scale: 1.0),
              u == url, !isClosing
        else { return }
        image = fallback
        withAnimation(HeroFlightMotion.settling(since: openedAt)) { displayRect = fitRect }
    }

    /// Pinch to zoom. The gesture reports a CUMULATIVE magnification, so the
    /// scale is applied to the zoom the pinch STARTED at — reading it as a
    /// delta compounds and the image leaps.
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard burnProgress <= 0 else { return }
                let start = magnifyStartZoom ?? zoom
                magnifyStartZoom = start
                let next = ViewerGeometry.clampZoom(start * value.magnification)
                zoom = next
                pan = ViewerGeometry.clampPan(pan, fittedSize: displayRect.size, zoom: next)
            }
            .onEnded { _ in magnifyStartZoom = nil }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                guard zoom > 1, burnProgress <= 0 else { return }
                if dragStartPan == nil {
                    // `push()` survives continuous mouse movement (unlike a
                    // bare `.set()`, which AppKit's per-mouse-move cursor
                    // recalculation clobbers the instant the pointer moves
                    // again) — confirmed live: an `.onHover`-triggered
                    // `.set()` reverted to the plain arrow on the very next
                    // move, while `push()`/`pop()` held reliably through an
                    // entire drag. `isHoverPushed` is left untouched here —
                    // dragging can only start while already hovering the
                    // zoomed image, so its openHand push is always further
                    // down the SAME stack; popping just this closedHand at
                    // drag-end reveals it again with no extra work.
                    isDraggingPan = true
                    NSCursor.closedHand.push()
                }
                let start = dragStartPan ?? pan
                dragStartPan = start
                pan = ViewerGeometry.clampPan(
                    CGSize(width: start.width + v.translation.width,
                           height: start.height + v.translation.height),
                    fittedSize: displayRect.size, zoom: zoom)
            }
            .onEnded { _ in
                dragStartPan = nil
                guard isDraggingPan else { return }
                isDraggingPan = false
                NSCursor.pop()
            }
    }

    /// Pushes/pops `NSCursor.openHand` to match "hovering the image AND
    /// zoomed past fit" — called on every hover transition and every zoom
    /// change (pinch/scroll/toolbar +/-/Fit, none of which move the mouse,
    /// so a plain hover-only check would miss a zoom change that happens
    /// while the pointer sits still over the image). Never touches the
    /// stack while `isDraggingPan`— its closedHand push is always ABOVE
    /// this one; popping this one out from under it would corrupt the
    /// LIFO order. Idempotent per state: only pushes/pops on an actual
    /// true→false/false→true transition, tracked via `isHoverPushed`.
    private func syncHoverCursor() {
        guard !isDraggingPan else { return }
        let shouldPush = isHoveringImage && zoom > 1
        if shouldPush && !isHoverPushed {
            isHoverPushed = true
            NSCursor.openHand.push()
        } else if !shouldPush && isHoverPushed {
            isHoverPushed = false
            NSCursor.pop()
        }
    }

    /// Unwinds whatever's on the cursor stack for this view, in LIFO order —
    /// the drag's closedHand (if mid-drag) before the hover's openHand.
    /// Called on close/flip/unmount so a viewer transition never leaves a
    /// stale push haunting the cursor stack for whatever comes next.
    private func resetCursorState() {
        if isDraggingPan { isDraggingPan = false; NSCursor.pop() }
        if isHoverPushed { isHoverPushed = false; NSCursor.pop() }
        isHoveringImage = false
    }
}
