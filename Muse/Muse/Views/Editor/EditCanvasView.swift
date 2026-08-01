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
import CoreImage

struct EditCanvasView: NSViewRepresentable {
    /// What to draw. nil renders nothing (the backdrop shows through).
    var image: CIImage?
    /// Optional second image + divider for split-wipe compare.
    var wipeAgainst: CIImage?
    var wipeFraction: Double?

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        // CI renders INTO the drawable's texture, so it can't be write-only.
        view.framebufferOnly = false
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.image = image
        context.coordinator.wipeAgainst = wipeAgainst
        context.coordinator.wipeFraction = wipeFraction
        nsView.setNeedsDisplay(nsView.bounds)
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

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let image, let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer()
            else { return }

            let drawableSize = view.drawableSize
            guard drawableSize.width >= 1, drawableSize.height >= 1 else { return }
            let composited = composite(image, in: drawableSize)

            let destination = CIRenderDestination(
                width: Int(drawableSize.width), height: Int(drawableSize.height),
                pixelFormat: view.colorPixelFormat, commandBuffer: commandBuffer,
                mtlTextureProvider: { drawable.texture })
            try? RenderContexts.preview.startTask(toRender: composited, to: destination)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        /// Fit into the drawable, centred, plus the wipe composite when one is
        /// active. Fitting here (rather than letting CI scale implicitly) is
        /// what keeps the two compared images in exact register — a wipe whose
        /// halves are scaled differently reads as a bug in the edit.
        private func composite(_ image: CIImage, in drawableSize: CGSize) -> CIImage {
            let fitted = fit(image, in: drawableSize)
            guard let wipeAgainst, let fraction = wipeFraction else { return fitted }
            let other = fit(wipeAgainst, in: drawableSize)
            let splitX = drawableSize.width * CGFloat(min(max(fraction, 0), 1))
            let leftHalf = other.cropped(to: CGRect(x: 0, y: 0, width: splitX,
                                                     height: drawableSize.height))
            return leftHalf.composited(over: fitted)
        }

        private func fit(_ image: CIImage, in size: CGSize) -> CIImage {
            let extent = image.extent
            guard extent.width > 0, extent.height > 0, extent.width.isFinite else { return image }
            let scale = min(size.width / extent.width, size.height / extent.height)
            let scaled = image
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let dx = (size.width - extent.width * scale) / 2
            let dy = (size.height - extent.height * scale) / 2
            return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        }
    }
}
