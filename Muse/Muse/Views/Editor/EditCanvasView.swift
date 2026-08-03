//
//  EditCanvasView.swift
//  Muse
//
//  The editor's pixel surface: an MTKView driven by `CIRenderDestination`.
//
//  This and the Core Image kernels are the app's SANCTIONED Metal surface —
//  which supersedes the older "no Metal shaders remain" note (that was about
//  the removed water/burn effects, not about a render pipeline).
//
//  `isPaused` + `enableSetNeedsDisplay`: the canvas draws only when the image
//  actually changes. A free-running MTKView would hold the GPU at 60fps for
//  the entire time the editor is open, which on a laptop is a fan and a
//  battery, not a feature.
//

import SwiftUI
import MetalKit
import AppKit
import CoreImage

struct EditCanvasView: NSViewRepresentable {
    /// What to draw. nil renders nothing (the backdrop shows through).
    var image: CIImage?
    /// The image to compare against — the original, or another version.
    var wipeAgainst: CIImage?
    /// Set for the SPLIT compare: the divider's position, 0…1.
    var wipeFraction: Double?
    /// Set for the SIDE-BY-SIDE compare: two whole images, before on the left.
    var sideBySide = false
    /// Spec 05 overlays, both composited AFTER the fit so they are screen-space
    /// patterns at canvas resolution — a zebra scaled with the image would
    /// moiré on a downscaled proxy.
    var zebrasOn = false
    /// The smoothed-EV mask + hovered zone for the hatch overlay. nil hides it.
    var zoneMask: CIImage?
    var hoveredZone: Int?
    /// Forwarded to the backing view so target mode can consume scroll before
    /// the canvas zooms. Returns true when it consumed the event.
    var onScrollWhileTargeting: ((NSEvent) -> Bool)?
    /// Canvas zoom (1 = fit) and pan in POINTS, matching the hero viewer's.
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    /// The free space the image FITS into, in points, measured from the view's
    /// edges. The view itself spans the window, so zooming pushes the photo
    /// under the panels instead of being clipped to a column between them.
    var fitInsets = EdgeInsets()

    func makeNSView(context: Context) -> MTKView {
        let view = CanvasMTKView()
        view.onScroll = { event in onScrollWhileTargeting?(event) ?? false }
        view.device = context.coordinator.device
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        // CI renders INTO the drawable's texture, so it can't be write-only.
        view.framebufferOnly = false
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        // RESIZE SYNC. Without these three the canvas visibly lagged a live
        // window resize: the view's bounds change immediately, but the drawable
        // presented on its own schedule, so for a frame or two the PREVIOUS
        // frame's texture was stretched to the new bounds by the layer — the
        // photo squashed, then snapped back once the next render landed. Owner
        // report: "the image size is being redrawn".
        //
        // `presentsWithTransaction` is the documented fix: it takes the
        // drawable's presentation out of the GPU's schedule and puts it in the
        // CoreAnimation transaction that is already committing the new bounds,
        // so bounds and pixels land in the SAME frame. It changes the present
        // call — see `draw(in:)`, which must commit, wait until scheduled, and
        // then present on the main thread. Don't set this without that.
        view.presentsWithTransaction = true
        // Implicit layer animations on a Metal layer interpolate the BOUNDS
        // while the texture inside doesn't, which is the stretch above with a
        // duration attached.
        view.layer?.actions = ["bounds": NSNull(), "position": NSNull(),
                               "contents": NSNull()]
        // The backstop for any frame that still slips through: a Metal layer's
        // default `contentsGravity` is `.resize`, which stretches the last
        // texture to whatever the new bounds are — INDEPENDENTLY in x and y.
        // That is the warp: drag a corner and the width lands first while the
        // height is still catching up, so for a frame or two the photo is a
        // different shape rather than a different size. `.resizeAspect` scales
        // the stale texture UNIFORMLY, so the worst case degrades from "wrong
        // shape" to "very slightly wrong size" — which is what the Preview
        // stage does, since a SwiftUI `Image` can only ever scale uniformly
        // inside a frame it fits into.
        view.layer?.contentsGravity = .resizeAspect
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.image = image
        context.coordinator.wipeAgainst = wipeAgainst
        context.coordinator.wipeFraction = wipeFraction
        context.coordinator.sideBySide = sideBySide
        context.coordinator.zebrasOn = zebrasOn
        context.coordinator.zoneMask = zoneMask
        context.coordinator.hoveredZone = hoveredZone
        context.coordinator.zoom = zoom
        context.coordinator.pan = pan
        context.coordinator.fitInsets = fitInsets
        (nsView as? CanvasMTKView)?.onScroll = { event in
            onScrollWhileTargeting?(event) ?? false
        }
        nsView.setNeedsDisplay(nsView.bounds)
    }

    /// The canvas's own NSView subclass, purely so target mode can intercept
    /// scroll: SwiftUI has no scroll gesture, and letting the event through
    /// would zoom the canvas while the user is adjusting a zone.
    final class CanvasMTKView: MTKView {
        var onScroll: ((NSEvent) -> Bool)?
        override func scrollWheel(with event: NSEvent) {
            if onScroll?(event) == true { return }
            super.scrollWheel(with: event)
        }

    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        /// One command queue for the view's lifetime. Creating one per frame
        /// is a documented Metal anti-pattern — it's an expensive object.
        private lazy var commandQueue = device?.makeCommandQueue()

        var image: CIImage?
        var wipeAgainst: CIImage?
        var wipeFraction: Double?
        var sideBySide = false
        var zebrasOn = false
        var zoneMask: CIImage?
        var hoveredZone: Int?
        var zoom: CGFloat = 1
        var pan: CGSize = .zero
        var fitInsets = EdgeInsets()
        /// Drawable pixels per point, so the pan (points) lands in the right
        /// place on a Retina drawable.
        private var pixelScale: CGFloat = 2

        /// Draw the new size NOW, in the resize's own pass.
        ///
        /// This was empty. With `isPaused` + `enableSetNeedsDisplay` the view
        /// only redraws when something marks it dirty, so a drawable that grew
        /// with the window kept showing the old frame — stretched to fit —
        /// until the next unrelated update happened to request a draw. Drawing
        /// synchronously here means every intermediate size of a live drag gets
        /// its own correctly-fitted frame.
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            CanvasTrace.log("willChange  passed=\(tr(size)) "
                + "bounds=\(tr(view.bounds.size)) "
                + "view.drawableSize=\(tr(view.drawableSize)) "
                + "layerDrawable=\(tr((view.layer as? CAMetalLayer)?.drawableSize ?? .zero)) "
                + "contentsScale=\(view.layer?.contentsScale ?? -1)")
            guard size.width >= 1, size.height >= 1 else { return }
            // WILL change — so the layer may not carry the new size yet, and
            // `view.currentDrawable` would hand back a texture of the OLD size.
            // Rendering a correctly-fitted frame into an old-sized surface and
            // letting the layer stretch it to the new bounds is the warp itself,
            // manufactured by the very code meant to prevent it. Setting the
            // layer's `drawableSize` first makes the next `currentDrawable` the
            // right size; it's what `autoResizeDrawable` is about to do anyway,
            // so this only makes the ordering explicit rather than assumed.
            // ASK for a frame; do not render one here.
            //
            // "willChange" is literal: `autoResizeDrawable` means MTKView owns
            // `drawableSize` and recomputes it from bounds AFTER it notifies this
            // delegate, so at THIS instant the layer's drawable is still the
            // previous size. Two rounds were spent rendering here anyway —
            // first calling `draw(in:)` directly, then setting
            // `metalLayer.drawableSize` and calling `view.draw()` — and the trace
            // showed the assignment silently ignored (the view owns it) and the
            // texture still the old size in every one of those frames. Rendering
            // a correctly-fitted image into a surface of the wrong size is what
            // produced the shrink-and-pop: `pixelScale` is `texture.width /
            // bounds.width`, so a stale texture inflated it to 3.3 instead of
            // 2.0 and the photo was fitted into a third of its proper width.
            //
            guard size.width >= 1, size.height >= 1 else { return }
            // Release the pooled old-size drawables and run the view's own draw
            // cycle. This does NOT fully fix the size — `autoResizeDrawable`
            // owns `drawableSize` and updates it after this call, so a minority
            // of frames still render into the previous size. See the log of
            // attempts in the staleness guard below; this is the best measured
            // configuration, not a correct one.
            view.releaseDrawables()
            view.draw()
        }

        func draw(in view: MTKView) {
            guard let image, let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer()
            else { return }

            // The DRAWABLE's own texture, not `view.drawableSize`. They agree
            // in steady state, but `drawableSizeWillChange` fires while the
            // change is still in flight, and rendering a frame sized from a
            // property that hasn't caught up puts a correctly-fitted image
            // into a differently-sized surface — a stretch, which is the
            // artifact this whole path exists to remove. The texture is the
            // surface actually being written, so it cannot disagree.
            let drawableSize = CGSize(width: drawable.texture.width,
                                      height: drawable.texture.height)
            guard drawableSize.width >= 1, drawableSize.height >= 1 else { return }
            // Derived from the drawable and the view's own bounds, NOT from the
            // layer's `contentsScale`.
            //
            // Tried the latter on 2026-08-02, on the theory that `bounds` is
            // stale during `drawableSizeWillChange` and so this ratio must be
            // wrong mid-drag. The owner reported the result as worse, with MORE
            // delay, and it was reverted. The theory was wrong somewhere — most
            // likely the two do agree here (MTKView derives `drawableSize` from
            // `bounds × contentsScale`, so the ratio just gives the scale back),
            // which means the substitution changed nothing about correctness
            // and only removed the one value that tracks the drawable actually
            // being drawn into. Don't re-try it without a measurement showing
            // the two genuinely disagree during a resize.
            pixelScale = view.bounds.width > 0 ? drawableSize.width / view.bounds.width : 2
            // Composited over a TRANSPARENT full-drawable rect. Metal recycles
            // drawables, and CI writes only the pixels its result covers — so a
            // frame that shrinks (zoom out, Fit, or coming back from hidden
            // controls) left the previous, larger frame's pixels around the new
            // one: the photo appeared duplicated at the edges.
            let stale = CanvasTrace.enabled && {
                let scale = view.layer?.contentsScale ?? 2
                return abs(view.bounds.width * scale - drawableSize.width) > 1
                    || abs(view.bounds.height * scale - drawableSize.height) > 1
            }()
            // Staleness is REPORTED (in the trace only), not acted on.
            //
            // Four configurations were measured on 2026-08-02, against a trace
            // of real drags:
            //   1. draw directly in willChange   — 59% of frames wrong-sized,
            //      worst 66% off. The shrink-and-pop.
            //   2. + assign metalLayer.drawableSize, releaseDrawables, view.draw()
            //      — 16% wrong by >1%, 3% badly wrong. Owner: "much better".
            //      The assignment itself is ignored (the view owns it).
            //   3. mark needsDisplay instead of drawing — 0% wrong, but a live
            //      drag never services needsDisplay, so the canvas FROZE mid-drag
            //      (32 frames in a session). Owner: "worse".
            //   4. autoResizeDrawable = false + own the size in setFrameSize —
            //      correct by construction, but nothing rendered at all.
            // (2) ships. Skipping the stale frames on top of it was not tried
            // separately and would leave the last good frame up, uniformly
            // scaled by `.resizeAspect`; it may be worth measuring, but not by
            // guessing. The remaining 3% is the residual settle.
            CanvasTrace.log((stale ? "draw STALE  " : "draw        ") + "texture=\(tr(drawableSize)) "
                + "bounds=\(tr(view.bounds.size)) "
                + "view.drawableSize=\(tr(view.drawableSize)) "
                + "pixelScale=\(String(format: "%.3f", pixelScale)) "
                + "imageExtent=\(tr(image.extent)) "
                + "free=\(tr(freeRect(in: drawableSize))) "
                + "fitted=\(tr(fit(image, in: drawableSize).extent)) "
                + "zoom=\(String(format: "%.3f", zoom))")
            let full = CGRect(origin: .zero, size: drawableSize)
            let composited = overlays(on: composite(image, in: drawableSize), size: drawableSize)
                .cropped(to: full)
                .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                    .cropped(to: full))

            let destination = CIRenderDestination(
                width: Int(drawableSize.width), height: Int(drawableSize.height),
                pixelFormat: view.colorPixelFormat, commandBuffer: commandBuffer,
                mtlTextureProvider: { drawable.texture })
            // Returns a CIRenderTask for callers that want to await timing; the
            // canvas just presents the drawable, so discard it explicitly.
            _ = try? RenderContexts.preview.startTask(toRender: composited, to: destination)
            // `presentsWithTransaction` (set in makeNSView) forbids
            // `commandBuffer.present(drawable)`: presentation has to happen on
            // THIS thread, inside the CoreAnimation transaction that is
            // committing the view's new bounds, or the pixels arrive a frame
            // after the geometry. Commit → wait until scheduled → present is
            // the required order.
            commandBuffer.commit()
            commandBuffer.waitUntilScheduled()
            drawable.present()
        }

        /// Fit into the drawable, centred, plus the wipe composite when one is
        /// active. Fitting here (rather than letting CI scale implicitly) is
        /// what keeps the two compared images in exact register — a wipe whose
        /// halves are scaled differently reads as a bug in the edit.
        private func composite(_ image: CIImage, in drawableSize: CGSize) -> CIImage {
            // SIDE BY SIDE: two WHOLE images, each fitted into half the free
            // width. This never drew before — the mode only put "Before" and
            // "After" captions over a single unchanged canvas, which is why it
            // read as doing nothing.
            if sideBySide, let wipeAgainst {
                let gap: CGFloat = 8 * pixelScale
                let (left, right) = halves(of: freeRect(in: drawableSize), gap: gap)
                return fit(image, into: right)
                    .composited(over: fit(wipeAgainst, into: left))
            }
            let fitted = fit(image, in: drawableSize)
            guard let wipeAgainst, let fraction = wipeFraction else { return fitted }
            let other = fit(wipeAgainst, in: drawableSize)
            let splitX = drawableSize.width * CGFloat(min(max(fraction, 0), 1))
            let leftHalf = other.cropped(to: CGRect(x: 0, y: 0, width: splitX,
                                                     height: drawableSize.height))
            return leftHalf.composited(over: fitted)
        }

        /// Zebras first, then the zone hatch — the hatch is a hover-scoped
        /// inspection tool and should win where both apply.
        private func overlays(on image: CIImage, size: CGSize) -> CIImage {
            var out = image
            if zebrasOn, let kernel = EditKernels.zebraStripes {
                out = kernel.apply(extent: out.extent,
                                   roiCallback: { _, rect in rect },
                                   arguments: [out, Float(AppSettings.editorZebraHigh),
                                               Float(AppSettings.editorZebraLow), Float(0)]) ?? out
            }
            if let hoveredZone, let zoneMask, let kernel = EditKernels.zoneHatch {
                let mask = fit(zoneMask, in: size)
                out = kernel.apply(extent: out.extent,
                                   roiCallback: { _, rect in rect },
                                   arguments: [out, mask, Float(hoveredZone)]) ?? out
            }
            return out
        }

        /// Fit, then zoom about the centre and pan. Applied here so the image,
        /// the compared image and the zone mask all move as one — and so the
        /// hit-testing math (CanvasPointMath, which already takes zoom/pan) is
        /// describing what is actually on screen.
        /// The space an image FITS into: the drawable minus the panels. In
        /// drawable pixels, and in CI's bottom-left origin.
        private func freeRect(in size: CGSize) -> CGRect {
            let leading = fitInsets.leading * pixelScale
            let trailing = fitInsets.trailing * pixelScale
            // CI's origin is bottom-left, the insets' is top-left.
            let bottom = fitInsets.top * pixelScale
            let top = fitInsets.bottom * pixelScale
            return CGRect(x: leading, y: top,
                          width: max(1, size.width - leading - trailing),
                          height: max(1, size.height - top - bottom))
        }

        private func halves(of rect: CGRect, gap: CGFloat) -> (CGRect, CGRect) {
            let w = max(1, (rect.width - gap) / 2)
            return (CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height),
                    CGRect(x: rect.maxX - w, y: rect.minY, width: w, height: rect.height))
        }

        private func fit(_ image: CIImage, in size: CGSize) -> CIImage {
            fit(image, into: freeRect(in: size))
        }

        /// Fit into `rect`, then zoom about its centre and pan. The ZOOM is not
        /// clamped to the rect, so the image grows past it and under the panels.
        private func fit(_ image: CIImage, into rect: CGRect) -> CIImage {
            let extent = image.extent
            guard extent.width > 0, extent.height > 0, extent.width.isFinite else { return image }
            let scale = min(rect.width / extent.width, rect.height / extent.height) * zoom
            let scaled = image
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let dx = rect.minX + (rect.width - extent.width * scale) / 2 + pan.width * pixelScale
            let dy = rect.minY + (rect.height - extent.height * scale) / 2 - pan.height * pixelScale
            return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        }
    }
}
