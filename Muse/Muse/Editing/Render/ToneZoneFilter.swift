//
//  ToneZoneFilter.swift
//  Muse
//
//  Render stage 2b: edge-aware per-zone exposure on un-clamped linear
//  working-space data — AFTER tone, BEFORE curve. A single per-pixel gain on
//  all three channels, so it is hue-preserving by construction and an exact
//  identity at zero gains.
//
//  `smoothedEVMap` is a PUBLIC hook with three consumers: this render stage,
//  the stats tap's zone mass, and the hover/overlay's EV sampling. One mask, by
//  construction — the number the user scrolls is the number the hatch draws.
//

import CoreImage
import CoreGraphics

nonisolated enum ToneZoneFilter {
    /// Scale-normalized like every radius in the pipeline — this is what keeps
    /// a thumbnail, the on-screen proxy and an export agreeing.
    static let guidedRadiusFraction: CGFloat = 0.05
    static let guidedEpsilon: Float = 0.25
    /// The guide is low-frequency by design; computing it above this buys
    /// nothing but time.
    static let guideWorkingLongEdgeCap: CGFloat = 1024

    /// Apply the zone gains to linear working-space RGB. `sourceLongEdge` is
    /// the CURRENT render's long edge, so the guided radius resolves to the
    /// same fraction of the picture at every resolution.
    static func apply(_ params: ToneZoneParams, to image: CIImage,
                      sourceLongEdge: CGFloat) -> CIImage {
        guard !params.isNeutral, let kernel = EditKernels.toneZoneGain else { return image }
        let g = params.clamped().gains
        let smoothed = smoothedEVMap(for: image, longEdge: sourceLongEdge)
        var arguments: [Any] = [image, smoothed]
        for value in g { arguments.append(Float(value)) }
        return kernel.apply(extent: image.extent,
                            roiCallback: { _, rect in rect },
                            arguments: arguments) ?? image
    }

    /// The edge-aware smoothed log2-luminance mask, computed at a capped
    /// working resolution and scaled back to the source extent (a Core Image
    /// colour kernel samples both inputs at the destination coordinate, so the
    /// mask must cover the same extent as the image).
    ///
    /// Guide = log2(Rec.709 luma); smoothing = a self-guided guided filter
    /// (box means via CIBoxBlur, the linear-model arithmetic in Metal).
    static func smoothedEVMap(for image: CIImage, longEdge: CGFloat) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite,
              let log2Luma = EditKernels.tzLog2Luma
        else { return image }

        let sourceLongEdge = max(extent.width, extent.height)
        let workingLongEdge = min(max(longEdge, 1), guideWorkingLongEdgeCap)
        let scale = min(workingLongEdge / sourceLongEdge, 1)
        let working = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image

        guard let guide = log2Luma.apply(extent: working.extent,
                                         roiCallback: { _, r in r },
                                         arguments: [working])
        else { return image }

        // The radius is a fraction of the WORKING long edge, which is itself a
        // fixed fraction of the source — so it stays the same fraction of the
        // picture whatever resolution we render at.
        let radius = max(guidedRadiusFraction * max(working.extent.width, working.extent.height), 1)

        var smoothed = guide
        if let square = EditKernels.tzSquare,
           let coeffsKernel = EditKernels.tzLinearCoeffs,
           let applyKernel = EditKernels.tzApplyCoeffs,
           let squared = square.apply(extent: guide.extent, roiCallback: { _, r in r },
                                      arguments: [guide]) {
            let blurredSquare = squared.clampedToExtent()
                .applyingFilter("CIBoxBlur", parameters: ["inputRadius": radius])
                .cropped(to: guide.extent)
            if let coeffs = coeffsKernel.apply(extent: guide.extent, roiCallback: { _, r in r },
                                               arguments: [blurredSquare, guidedEpsilon]) {
                let blurredCoeffs = coeffs.clampedToExtent()
                    .applyingFilter("CIBoxBlur", parameters: ["inputRadius": radius])
                    .cropped(to: guide.extent)
                smoothed = applyKernel.apply(extent: guide.extent, roiCallback: { _, r in r },
                                             arguments: [guide, blurredCoeffs]) ?? guide
            }
        }

        guard scale < 1 else { return smoothed }
        return smoothed
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .cropped(to: extent)
    }

    /// Read the smoothed EV map back as a CPU buffer — the stats tap's zone
    /// mass and the target-mode hover readout both sample this.
    static func evBuffer(for image: CIImage, longEdge: Int,
                         context: CIContext) -> ZoneEVMap? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite
        else { return nil }
        let sourceLongEdge = max(extent.width, extent.height)
        let scale = min(CGFloat(longEdge) / sourceLongEdge, 1)
        let sampled = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        let map = smoothedEVMap(for: sampled, longEdge: CGFloat(longEdge))
        let rect = map.extent.intersection(sampled.extent)
        let width = Int(rect.width.rounded(.down))
        let height = Int(rect.height.rounded(.down))
        guard width > 0, height > 0 else { return nil }

        var floats = [Float](repeating: 0, count: width * height * 4)
        floats.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(map, toBitmap: base, rowBytes: width * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: rect.minX, y: rect.minY,
                                          width: CGFloat(width), height: CGFloat(height)),
                           format: .RGBAf, colorSpace: nil)
        }
        // The guide is replicated across channels; read the red one. Flip to
        // top-down rows so callers can index it like a screen buffer.
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let sourceRow = height - 1 - y
            for x in 0..<width {
                values[y * width + x] = floats[(sourceRow * width + x) * 4]
            }
        }
        return ZoneEVMap(width: width, height: height, values: values)
    }
}
