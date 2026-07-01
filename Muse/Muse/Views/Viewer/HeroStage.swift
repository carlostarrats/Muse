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

struct HeroStage: View {
    let url: URL
    let sourceFrame: CGRect          // tile frame, global coords
    let viewport: CGSize
    var burnProgress: Double = 0
    var onCloseFinished: () -> Void

    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    @Binding var isClosing: Bool     // set true by parent to run the return flight

    @State private var displayRect: CGRect = .zero
    @State private var image: NSImage?
    @State private var dragStartPan: CGSize? = nil
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
        ViewerGeometry.fitRect(imageSize: image?.size ?? sourceFrame.size,
                               viewport: viewport)
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
                    .aspectRatio(contentMode: .fill)
                    .frame(width: base.width, height: base.height)
                    .clipShape(Rectangle())
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
                    .onHover { hovering in
                        isHoveringImage = hovering
                        syncHoverCursor()
                    }
            }
        }
        .onAppear { open() }
        .onDisappear { resetCursorState() }
        .onChange(of: isClosing) { _, closing in if closing { close() } }
        .onChange(of: zoom) { _, _ in syncHoverCursor() }
        .onChange(of: sourceFrame) { _, newFrame in
            // The toolbar returns as the close flight starts, shifting the
            // grid — retarget mid-flight so we land on the tile's real spot.
            guard isClosing else { return }
            withAnimation(.timingCurve(0.3, 1.08, 0.35, 1, duration: 0.22)) {
                displayRect = newFrame
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
                withAnimation(.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.4)) {
                    displayRect = fitRect
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { displayRect = fitRect }
            }
        }
        .task(id: url) { await loadFullRes() }
    }

    private func open() {
        openedAt = Date()
        displayRect = sourceFrame
        // The grid tile's thumbnail is already in memory — start the flight
        // with it immediately. Awaiting QLThumbnailGenerator here added
        // 100–400ms of dead time before the open animation even began.
        if let quick = Self.quickThumbnail(for: url) {
            image = quick
            withAnimation(.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.4)) {
                displayRect = fitRect
            }
        } else {
            Task {
                image = await ThumbnailCache.shared.thumbnail(
                    for: url, size: CGSize(width: 320, height: 320))
                withAnimation(.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.4)) {
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

    private func close() {
        resetCursorState()
        withAnimation(.timingCurve(0.3, 1.08, 0.35, 1, duration: 0.34)) {
            zoom = 1; pan = .zero
            displayRect = sourceFrame
            shadowVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { onCloseFinished() }
    }

    private func flipTo() {
        resetCursorState()
        zoom = 1; pan = .zero
        // thumbnail swaps in fast; .task(id: url) handles the full-res load
        if let quick = Self.quickThumbnail(for: url) {
            image = quick
            withAnimation(.easeOut(duration: 0.2)) { displayRect = fitRect }
        } else {
            Task {
                image = await ThumbnailCache.shared.thumbnail(
                    for: url, size: CGSize(width: 320, height: 320))
                withAnimation(.easeOut(duration: 0.2)) { displayRect = fitRect }
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
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: target,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let img, u == url {
            image = img
            withAnimation(.easeOut(duration: 0.2)) { displayRect = fitRect }
            return
        }
        // ImageIO returned nil — the source isn't decodable by it (e.g. a RAW
        // format Apple's camera codec doesn't support). Fall back to the shared
        // thumbnail path, which tries QuickLook's best representation (some
        // formats render there even when ImageIO can't) and otherwise yields the
        // system type icon — anything is better than leaving the viewer blank.
        guard u == url,
              let fallback = await ThumbnailCache.shared.thumbnail(
                  for: u, size: CGSize(width: target, height: target), scale: 1.0),
              u == url
        else { return }
        image = fallback
        withAnimation(.easeOut(duration: 0.2)) { displayRect = fitRect }
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
