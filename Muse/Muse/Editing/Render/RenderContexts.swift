//
//  RenderContexts.swift
//  Muse
//
//  Two contexts, for two very different jobs.
//
//  The PREVIEW context is long-lived and caches intermediates: a slider drag
//  re-renders the same image dozens of times a second, and rebuilding the
//  filter graph's intermediates each time is what makes an editor feel sticky.
//
//  The EXPORT context is created per export and released after, with caching
//  OFF and a memory target: a 60 MP export's intermediates are hundreds of MB,
//  and letting them accumulate in the preview context's cache is how an M1 Air
//  gets memory-pressure killed halfway through a batch. (There is no Extended
//  Virtual Addressing entitlement on macOS — that's iOS-only — so the ceiling
//  is real and has to be respected rather than raised.)
//
//  Working space is stated EXPLICITLY on both. Core Image's default working
//  space has changed across OS releases; relying on it means the same stack
//  renders differently on two machines.
//

import CoreImage
import Metal

nonisolated enum RenderContexts {
    static let preview: CIContext = {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: true,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
            .name: "muse.edit.preview",
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    /// One GB. Fresh per export, released after.
    static let exportMemoryLimit = 1_073_741_824

    static func makeExportContext() -> CIContext {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
            .memoryTarget: exportMemoryLimit,
            .name: "muse.edit.export",
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }
}
