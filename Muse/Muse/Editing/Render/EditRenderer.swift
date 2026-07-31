//
//  EditRenderer.swift
//  Muse
//
//  The fixed render chain. Its ORDER is code, never data — the stack is a set
//  of parameters, and reordering it is deliberately unrepresentable. That is
//  what lets a stack copied from one photo to another mean the same thing.
//
//  Chain: decode/orient → geometry → tone (exposure → WB → toneBands →
//  contrast) → curve → color (vibrance → saturation) → presence (NR → clarity
//  → texture → sharpen) → vignette.
//
//  Scene-referred throughout except the curve, which is the deliberate
//  display-referred pocket (a point curve the user drew in a 0…1 box has to be
//  evaluated in that box). Everything before it runs on un-clamped linear data
//  so highlight recovery works on real headroom instead of flat white.
//
//  SCALE RULE: every radius is `fraction × sourceLongEdge`, scaled by the
//  actual decode ratio. A fixed pixel radius makes a thumbnail and an export
//  disagree, which is the one class of bug that shows up as "the grid doesn't
//  match what I edited". `EditRenderConsistencyTests` is the permanent gate.
//

import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated enum EditRenderer {

    // MARK: - Renderability

    /// A stack from a NEWER renderer decodes (so its blob round-trips) but
    /// must NOT be rendered — a partial application of parameters we only half
    /// understand would look like a bug the user can't undo. The original
    /// renders instead, and the blob is left byte-identical.
    static func canRender(_ stack: EditStack) -> Bool {
        stack.processVersion <= EditStack.currentProcessVersion
    }

    // MARK: - The chain

    /// `sourceLongEdge` is the long edge of the image AS PASSED IN, so every
    /// fractional radius resolves to the right pixel count at this resolution.
    static func apply(_ stack: EditStack, to image: LinearImage,
                      sourceLongEdge: CGFloat) -> LinearImage {
        guard canRender(stack) else { return image }
        var current = image.ciImage

        if let geo = stack.geometryParams, !geo.isNeutral {
            current = applyGeometry(geo, to: current)
        }
        // Radii scale with the POST-geometry frame: a crop changes what "1% of
        // the long edge" means on screen, and the user tunes clarity against
        // what they can see.
        let longEdge = max(current.extent.width, current.extent.height)
        let radiusScale = longEdge.isFinite && longEdge > 0 ? longEdge : sourceLongEdge

        if let tone = stack.toneParams, !tone.isNeutral {
            current = applyTone(tone.clamped(), to: current)
        }
        // Temperature/tint for ENCODED sources only. RAW already had these
        // applied at demosaic by `RawSource` — applying them again here would
        // double-correct.
        if let color = stack.colorParams, stack.rawParams == nil,
           color.temperature != 0 || color.tint != 0 {
            current = applyWhiteBalance(color.clamped(), to: current)
        }
        if let curve = stack.curveParams, !curve.isNeutral {
            current = applyCurve(curve.clamped(), to: current)
        }
        if let color = stack.colorParams, color.vibrance != 0 || color.saturation != 0 {
            current = applyColor(color.clamped(), to: current)
        }
        if let presence = stack.presenceParams, !presence.isNeutral {
            current = applyPresence(presence.clamped(), to: current,
                                    radiusScale: radiusScale, isRaw: stack.rawParams != nil)
        }
        if let vignette = stack.vignetteParams, !vignette.isNeutral {
            current = applyVignette(vignette.clamped(), to: current)
        }
        return LinearImage(current)
    }

    // MARK: - Stages

    private static func applyGeometry(_ geo: GeometryParams, to image: CIImage) -> CIImage {
        var out = image
        if geo.straightenDegrees != 0 {
            let radians = geo.straightenDegrees * .pi / 180
            out = out.transformed(by: CGAffineTransform(rotationAngle: CGFloat(-radians)))
        }
        if let crop = geo.crop, !crop.isFull {
            let e = out.extent
            guard e.width.isFinite, e.height.isFinite else { return out }
            // The crop rect is in DISPLAY-oriented unit coordinates with the
            // origin top-left; CIImage's origin is bottom-left, hence the flip
            // on y. Getting this wrong crops the wrong band and looks like an
            // off-by-one in the editor's crop handles.
            let rect = CGRect(x: e.minX + CGFloat(crop.x) * e.width,
                              y: e.minY + CGFloat(1 - crop.y - crop.h) * e.height,
                              width: CGFloat(crop.w) * e.width,
                              height: CGFloat(crop.h) * e.height)
            out = out.cropped(to: rect)
            // Re-origin so downstream extent maths (radii, vignette centre) is
            // relative to the cropped frame, not the original.
            out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX,
                                                        y: -out.extent.minY))
        }
        if geo.flipH { out = out.oriented(forExifOrientation: 2) }
        if geo.flipV { out = out.oriented(forExifOrientation: 4) }
        switch ((geo.quarterTurns % 4) + 4) % 4 {
        case 1: out = out.oriented(forExifOrientation: 6)   // 90° CW
        case 2: out = out.oriented(forExifOrientation: 3)   // 180°
        case 3: out = out.oriented(forExifOrientation: 8)   // 90° CCW
        default: break
        }
        return out
    }

    private static func applyTone(_ tone: ToneParams, to image: CIImage) -> CIImage {
        var out = image
        if tone.exposureEV != 0 {
            out = out.applyingFilter("CIExposureAdjust",
                                     parameters: [kCIInputEVKey: tone.exposureEV])
        }
        if tone.highlights != 0 || tone.shadows != 0 || tone.whites != 0 || tone.blacks != 0,
           let kernel = EditKernels.toneBands {
            // A nil kernel (broken metallib) SKIPS the stage rather than
            // crashing — the photo still renders, minus this effect.
            let extent = out.extent
            out = kernel.apply(extent: extent, arguments: [
                out, Float(tone.highlights), Float(tone.shadows),
                Float(tone.whites), Float(tone.blacks),
            ]) ?? out
        }
        if tone.contrast != 0 {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1 + 0.75 * tone.contrast,
                kCIInputSaturationKey: 1, kCIInputBrightnessKey: 0,
            ])
        }
        return out
    }

    private static func applyWhiteBalance(_ color: ColorParams, to image: CIImage) -> CIImage {
        let miredOffset = MiredMapping.miredOffset(forSliderValue: color.temperature)
        // Neutral is D65; positive slider = warmer = a LOWER target Kelvin.
        let targetKelvin = MiredMapping.kelvin(from: 6500, miredOffset: miredOffset)
        return image.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: CGFloat(targetKelvin), y: CGFloat(color.tint * 50)),
            "inputTargetNeutral": CIVector(x: 6500, y: 0),
        ])
    }

    private static func applyCurve(_ curve: CurveParams, to image: CIImage) -> CIImage {
        var out = image
        // The composite RGB curve first, then per-channel — the order a user
        // expects from every other editor.
        out = applyChannelCurve(points: curve.rgb, to: out, channels: [0, 1, 2])
        out = applyChannelCurve(points: curve.red, to: out, channels: [0])
        out = applyChannelCurve(points: curve.green, to: out, channels: [1])
        out = applyChannelCurve(points: curve.blue, to: out, channels: [2])
        return out
    }

    private static func applyChannelCurve(points: [CurveParams.Point], to image: CIImage,
                                          channels: [Int]) -> CIImage {
        guard points.count >= 2 else { return image }
        let lut = CurveLUT.build(points: points)
        // `CIColorCurves` samples a small evenly-spaced table; 64 entries is
        // plenty for a hand-drawn curve and keeps the data object tiny.
        let sampleCount = 64
        var values: [Float] = []
        values.reserveCapacity(sampleCount * 3)
        for i in 0..<sampleCount {
            let t = Float(i) / Float(sampleCount - 1)
            let mapped = lut[min(Int(t * Float(lut.count - 1)), lut.count - 1)]
            for c in 0..<3 {
                values.append(channels.contains(c) ? mapped : t)
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        // sRGB explicitly: the curve is the chain's ONE display-referred stage,
        // and evaluating a 0…1 curve against linear data would bunch every
        // control point into the bottom stop. `CIToneCurve` is never used
        // anywhere in the app — it's a 5-point fixed shape, not a real curve.
        return image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": data,
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB) as Any,
        ])
    }

    private static func applyColor(_ color: ColorParams, to image: CIImage) -> CIImage {
        var out = image
        if color.vibrance != 0 {
            out = out.applyingFilter("CIVibrance", parameters: ["inputAmount": color.vibrance])
        }
        if color.saturation != 0 {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + color.saturation,
                kCIInputContrastKey: 1, kCIInputBrightnessKey: 0,
            ])
        }
        return out
    }

    private static func applyPresence(_ presence: PresenceParams, to image: CIImage,
                                      radiusScale: CGFloat, isRaw: Bool) -> CIImage {
        var out = image
        // RAW already had NR and sharpening applied at demosaic (RawSource
        // routes the same slider values there), so re-applying here would
        // double them.
        if !isRaw {
            if presence.noiseReduction > 0 {
                out = out.applyingFilter("CINoiseReduction", parameters: [
                    "inputNoiseLevel": 0.02 * presence.noiseReduction,
                    "inputSharpness": 0.4,
                ])
            }
        }
        if presence.clarity != 0 {
            out = localContrast(out, amount: presence.clarity,
                                radius: EditKernels.clarityRadiusFraction * radiusScale)
        }
        if presence.texture != 0 {
            out = localContrast(out, amount: presence.texture,
                                radius: EditKernels.textureRadiusFraction * radiusScale)
        }
        if !isRaw, presence.sharpen > 0 {
            out = out.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(EditKernels.sharpenRadiusFraction * radiusScale, 0.5),
                kCIInputIntensityKey: presence.sharpen,
            ])
        }
        return out
    }

    private static func localContrast(_ image: CIImage, amount: Double,
                                      radius: CGFloat) -> CIImage {
        guard let kernel = EditKernels.clarityTexture else { return image }
        let extent = image.extent
        // Clamp before blurring: a plain blur samples transparent black past
        // the edge and darkens the border into a visible frame.
        let blurred = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(radius, 0.5)])
            .cropped(to: extent)
        return kernel.apply(extent: extent,
                            roiCallback: { _, rect in rect },
                            arguments: [image, blurred, Float(amount)]) ?? image
    }

    private static func applyVignette(_ vignette: VignetteParams, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0 else { return image }
        let longEdge = max(extent.width, extent.height)
        return image.applyingFilter("CIVignetteEffect", parameters: [
            kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
            kCIInputRadiusKey: longEdge * EditKernels.vignetteRadiusFraction
                * CGFloat(0.5 + vignette.midpoint),
            kCIInputIntensityKey: vignette.amount,
            "inputFalloff": vignette.feather,
        ])
    }

    // MARK: - Entry points

    /// Decode `url` bounded to `maxPixel`, apply `stack`, return a CGImage.
    /// The one function every pixel consumer (thumbnails, hero, PDF) calls.
    static func render(url: URL, stack: EditStack, maxPixel: Int) -> CGImage? {
        guard canRender(stack), let source = decode(url: url, stack: stack, maxPixel: maxPixel)
        else { return nil }
        let rendered = apply(stack, to: source.image, sourceLongEdge: source.longEdge)
        let context = RenderContexts.preview
        let extent = rendered.ciImage.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite
        else { return nil }
        return context.createCGImage(rendered.ciImage, from: extent,
                                     format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Full-resolution render straight to a file — the export path. Uses a
    /// FRESH context that's released afterwards: an export's intermediates are
    /// enormous and must not be cached into the long-lived preview context.
    static func exportFile(url: URL, stack: EditStack, to dest: URL,
                           format: OutputFormat) throws {
        guard canRender(stack), let source = decode(url: url, stack: stack, maxPixel: 0)
        else { throw RenderError.decodeFailed }
        let rendered = apply(stack, to: source.image, sourceLongEdge: source.longEdge)
        let extent = rendered.ciImage.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite
        else { throw RenderError.decodeFailed }
        let context = RenderContexts.makeExportContext()
        guard let cgImage = context.createCGImage(rendered.ciImage, from: extent,
                                                  format: .RGBA8,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { throw RenderError.renderFailed }
        try write(cgImage, to: dest, format: format)
    }

    enum RenderError: Error { case decodeFailed, renderFailed, encodeFailed }

    // MARK: - Decode

    private struct Source { let image: LinearImage; let longEdge: CGFloat }

    /// `maxPixel == 0` means full resolution (export). RAW goes through
    /// `CIRAWFilter`; everything else through `CIImage(contentsOf:)`, which
    /// hands back working-space data with the file's transfer function already
    /// applied and its EXIF orientation already honoured.
    private static func decode(url: URL, stack: EditStack, maxPixel: Int) -> Source? {
        let linear: LinearImage
        if isRawURL(url) {
            guard let raw = RawSource.decode(url: url, params: stack.rawParams,
                                             color: stack.colorParams ?? .neutral,
                                             presence: stack.presenceParams ?? .neutral)
            else { return nil }
            linear = raw
        } else {
            guard let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            else { return nil }
            linear = LinearImage.alreadyDecodedFromFile(ci)
        }
        var image = linear.ciImage
        let fullLongEdge = max(image.extent.width, image.extent.height)
        guard fullLongEdge.isFinite, fullLongEdge > 0 else { return nil }
        if maxPixel > 0, fullLongEdge > CGFloat(maxPixel) {
            let ratio = CGFloat(maxPixel) / fullLongEdge
            image = image.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        }
        let longEdge = max(image.extent.width, image.extent.height)
        return Source(image: LinearImage(image), longEdge: longEdge)
    }

    static func isRawURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased())
        else { return false }
        return type.conforms(to: .rawImage)
    }

    // MARK: - Encode

    private static func write(_ image: CGImage, to dest: URL, format: OutputFormat) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            dest as CFURL, format.utType.identifier as CFString, 1, nil)
        else { throw RenderError.encodeFailed }
        var properties: [CFString: Any] = [:]
        if let quality = format.quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.encodeFailed }
    }
}

/// Container + quality for a rendered output. Named constants rather than
/// magic numbers at each call site, so "what does Muse export a JPEG at"
/// has exactly one answer.
nonisolated enum OutputFormat: Equatable, Sendable {
    case jpeg, png, tiff, heic, tiff16

    static let jpegQuality = 0.92
    static let heicQuality = 0.9

    /// Keep the source's container where we can write it; RAW can't be
    /// written back, so a share path renders it to JPEG.
    static func matchingSource(_ url: URL) -> OutputFormat {
        switch url.pathExtension.lowercased() {
        case "png": .png
        case "tif", "tiff": .tiff
        case "heic", "heif": .heic
        default: .jpeg
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .tiff, .tiff16: .tiff
        case .heic: UTType("public.heic") ?? .jpeg
        }
    }

    var quality: Double? {
        switch self {
        case .jpeg: Self.jpegQuality
        case .heic: Self.heicQuality
        case .png, .tiff, .tiff16: nil
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .tiff, .tiff16: "tif"
        case .heic: "heic"
        }
    }
}
