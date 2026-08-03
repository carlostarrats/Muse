//
//  SocialRender.swift
//  Muse
//
//  The fixed render pipeline for social export. Every step is a named constant,
//  and the ORDER is code, never data:
//
//    1  OutputRender.forOutput      — the export choke point comes FIRST, so an
//                                     edited photo goes out with its edits.
//    2  withinDecodeBudget          — bomb guard before any full raster.
//    3  ImageIO thumbnail decode    — orientation BAKED (…WithTransform), so no
//                                     output orientation tag can ever exist.
//    4  fit compose                 — crop / matte / blur-extend, fixed presets.
//    5  CIUnsharpMask               — ONLY when a downscale actually happened.
//    6  flatten + 8-bit sRGB
//    7  JPEG with the byte-target quality ladder
//    8  verify (X invariants, isClean) then write
//
//  Never upscales, globally: a source smaller than the target exports at its
//  native cropped size.
//
//  Platform-neutral: Foundation / CoreGraphics / CoreImage / ImageIO /
//  UniformTypeIdentifiers only — never AppKit.
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// `nonisolated`: the social export renders off-main.
nonisolated enum SocialRender {
    struct Job {
        var sourceURL: URL          // the ORIGINAL library URL — forOutput resolves edits
        var preset: SocialPreset
        var fit: SocialFit          // fixed presets only; ignored otherwise
        var matte: MatteShade
        /// Normalized, in the DECODED (display-oriented) image's space. nil =
        /// centered aspect-fill.
        var cropRect: CGRect?
        var includeEXIF: Bool
        var includeLocation: Bool   // only honored when includeEXIF
    }

    struct Result { let url: URL; let pixelSize: CGSize; let bytes: Int }

    enum RenderError: Error {
        case decodeFailed
        case tooLarge
        case encodeFailed
        case verifyFailed
        case xInvariantFailed(String)
    }

    // Pipeline constants — single declaration site.
    static let neverUpscale = true
    static let decodeCeilingFactor = 4        // decode ≤ 4 × the output long edge…
    static let decodeFloor = 4096             // …but never below this (crop headroom)
    static let sharpenStandard = (radius: 1.2, intensity: 0.5)   // CIUnsharpMask
    static let sharpenLight    = (radius: 0.8, intensity: 0.25)
    static let qualityStep = 0.05             // byte-target ladder
    static let qualityFloor = 0.70            // generic floor
    static let xQualityFloor = 0.55           // X trades quality for its no-recompress rule
    static let blurExtendRadiusFraction: CGFloat = 0.04
    static let xMaxDimension = 4096
    static let xMaxBytes = 5 * 1024 * 1024

    static func export(_ job: Job, to directory: URL) throws -> Result {
        // 1. Choke point — edited pixels ride here.
        let out = try OutputRender.forOutput(job.sourceURL)
        // The render temp exists only to be decoded below; collect it here
        // rather than leaving it for the 24 h launch sweep. No-op for an
        // unedited source (nothing was rendered).
        defer { OutputRender.discard(out) }

        // 2. Budget gate — header only, so a dimension bomb is refused before
        //    any raster exists. `ExportPipeline` owns this step for every
        //    exporter; the errors map back onto this enum so the public cases
        //    don't change.
        let sourceSize: CGSize
        do {
            sourceSize = try ExportPipeline.headerSize(url: out.url)
        } catch ExportPipeline.RenderError.tooLarge {
            throw RenderError.tooLarge
        } catch {
            throw RenderError.decodeFailed
        }

        let targetSize = Self.targetSize(for: job.preset.kind, sourceSize: sourceSize)

        // 3. Decode display-oriented at a bounded ceiling.
        let outputLongEdge = max(targetSize.width, targetSize.height)
        let sourceLongEdge = max(sourceSize.width, sourceSize.height)
        let decodeMax: Int
        switch job.preset.kind {
        case .original:
            decodeMax = Int(sourceLongEdge)
        default:
            decodeMax = Int(min(sourceLongEdge,
                                max(CGFloat(decodeFloor), CGFloat(decodeCeilingFactor) * outputLongEdge)))
        }
        let source: ExportPipeline.DecodedSource
        do {
            source = try ExportPipeline.load(url: out.url, decodeLongEdgeMax: decodeMax)
        } catch ExportPipeline.RenderError.tooLarge {
            throw RenderError.tooLarge
        } catch {
            throw RenderError.decodeFailed
        }
        let decoded = source.image
        let sourceProps = source.sourceProperties
        let decodedSize = source.decodedSize

        // 4. Fit compose.
        var ciImage = CIImage(cgImage: decoded)
        let didDownscale: Bool
        switch job.preset.kind {
        case .fixed(let w, let h):
            // Never upscale: when the source is smaller than the frame, the
            // whole composition shrinks to the largest frame the source fills.
            let frame = Self.fixedFrame(width: w, height: h, decodedSize: decodedSize)
            let targetAspect = frame.width / frame.height
            let cropRect = job.cropRect ?? SocialCropMath.rect(
                sourceSize: decodedSize, targetAspect: targetAspect,
                zoom: 1, center: CGPoint(x: 0.5, y: 0.5))
            switch job.fit {
            case .crop:
                ciImage = Self.crop(ciImage, normalized: cropRect, in: decodedSize)
                ciImage = Self.scale(ciImage, to: frame)
            case .matte:
                let fitted = Self.scaleAspectFit(ciImage, into: frame)
                ciImage = Self.composite(fitted, overMatte: job.matte, targetSize: frame)
            case .blurExtend:
                // The surround is a blown-up, blurred copy of the picture itself
                // — an aspect-FILL of the frame, softened, with the true fitted
                // image laid over it.
                let filled = Self.scale(
                    Self.crop(ciImage,
                              normalized: SocialCropMath.rect(sourceSize: decodedSize,
                                                              targetAspect: targetAspect,
                                                              zoom: 1,
                                                              center: CGPoint(x: 0.5, y: 0.5)),
                              in: decodedSize),
                    to: frame)
                let blurred = filled.clampedToExtent()
                    .applyingGaussianBlur(sigma: Double(blurExtendRadiusFraction * max(frame.width, frame.height)))
                    .cropped(to: CGRect(origin: .zero, size: frame))
                let fitted = Self.scaleAspectFit(ciImage, into: frame)
                ciImage = fitted.composited(over: blurred)
            }
            didDownscale = decodedSize.width > frame.width || decodedSize.height > frame.height
        case .longEdge(let cap):
            let targetLong = neverUpscale
                ? min(CGFloat(cap), max(decodedSize.width, decodedSize.height))
                : CGFloat(cap)
            let scale = targetLong / max(decodedSize.width, decodedSize.height)
            if scale < 1 {
                ciImage = Self.scale(ciImage, to: CGSize(width: (decodedSize.width * scale).rounded(),
                                                         height: (decodedSize.height * scale).rounded()))
            }
            didDownscale = scale < 1
        case .original:
            didDownscale = false
        }

        // 5. Output sharpen — only for an actual downscale (it exists to undo
        //    resampling softness, not to "improve" the picture).
        if didDownscale {
            let (radius, intensity): (Double, Double)
            switch job.preset.sharpen {
            case .none:     (radius, intensity) = (0, 0)
            case .light:    (radius, intensity) = sharpenLight
            case .standard: (radius, intensity) = sharpenStandard
            }
            if intensity > 0 {
                ciImage = ciImage.applyingFilter("CIUnsharpMask",
                    parameters: [kCIInputRadiusKey: radius, kCIInputIntensityKey: intensity])
            }
        }

        // 6. Flatten onto an opaque backing (JPEG has no alpha; a transparent
        //    PNG would otherwise composite against black) + 8-bit sRGB.
        let extent = ciImage.extent.integral
        guard extent.width >= 1, extent.height >= 1 else { throw RenderError.encodeFailed }
        let matteColor: CIColor = job.matte == .black ? .black : .white
        let flattened = ciImage.composited(over: CIImage(color: matteColor).cropped(to: extent))
        //    A social export is SDR by design — the platforms it targets don't
        //    render HDR reliably. But it must get there by TONE-MAPPING, not by
        //    letting createCGImage clamp: an HDR source's specular highlights
        //    would otherwise land as one flat white blob in the very picture
        //    someone is about to post.
        let toneMapped = HDRDecode.toneMappedToSDR(
            flattened, headroom: EditRenderer.sourceHeadroom(url: job.sourceURL))
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let finalCG = ExportPipeline.context.createCGImage(toneMapped, from: extent,
                                                  format: .RGBA8, colorSpace: sRGB)
        else { throw RenderError.encodeFailed }

        // 7. Encode with the byte-target ladder.
        let floor = job.preset.id == "x" ? xQualityFloor : qualityFloor
        var quality = job.preset.quality
        var data = try Self.encodeJPEG(finalCG, quality: quality, job: job, sourceProps: sourceProps)
        if let target = job.preset.byteTargetKB {
            while data.count > target * 1024 && quality > floor {
                quality = max(floor, quality - qualityStep)
                data = try Self.encodeJPEG(finalCG, quality: quality, job: job, sourceProps: sourceProps)
            }
        }
        let pixelSize = CGSize(width: finalCG.width, height: finalCG.height)
        if job.preset.id == "x" {
            // X carries no byte TARGET, but two of its invariants are byte
            // bounds (< 5 MB and < W×H) that a busy image misses at the starting
            // quality. Drive the ladder off the invariants themselves rather
            // than failing a file the floor could have saved.
            func meetsByteRules(_ d: Data) -> Bool {
                d.count < xMaxBytes
                    && Double(d.count) < Double(pixelSize.width * pixelSize.height)
            }
            while quality > xQualityFloor && meetsByteRules(data) == false {
                quality = max(xQualityFloor, quality - qualityStep)
                data = try Self.encodeJPEG(finalCG, quality: quality, job: job, sourceProps: sourceProps)
            }
            // Fail the FILE rather than ship a recompressible one.
            try Self.verifyXInvariants(data: data, pixelSize: pixelSize)
        }

        // 8. Verify, then write. A default-metadata output must be provably
        //    clean, not just constructed to be.
        if job.includeEXIF == false {
            guard ImageMetadataStripper.isClean(data) else { throw RenderError.verifyFailed }
        }
        let stem = job.sourceURL.deletingPathExtension().lastPathComponent
        let destURL = Self.collisionSafeURL(base: "\(stem)-\(job.preset.id)", ext: "jpg", in: directory)
        try data.write(to: destURL, options: .atomic)
        return Result(url: destURL, pixelSize: pixelSize, bytes: data.count)
    }

    // MARK: helpers

    /// The frame a fixed preset actually renders at: its declared dimensions,
    /// shrunk proportionally if the source can't fill them (never upscale).
    static func fixedFrame(width: Int, height: Int, decodedSize: CGSize) -> CGSize {
        let declared = CGSize(width: CGFloat(width), height: CGFloat(height))
        guard neverUpscale, decodedSize.width > 0, decodedSize.height > 0 else { return declared }
        let aspect = declared.width / declared.height
        // The largest frame of this aspect that the source can fill.
        let fillW = min(decodedSize.width, decodedSize.height * aspect)
        let scale = min(1, fillW / declared.width)
        guard scale < 1 else { return declared }
        return CGSize(width: max(1, (declared.width * scale).rounded()),
                      height: max(1, (declared.height * scale).rounded()))
    }

    private static func targetSize(for kind: SocialPreset.Kind, sourceSize: CGSize) -> CGSize {
        switch kind {
        case .fixed(let w, let h):
            return CGSize(width: w, height: h)
        case .longEdge(let cap):
            let long = neverUpscale ? min(CGFloat(cap), max(sourceSize.width, sourceSize.height)) : CGFloat(cap)
            let aspect = sourceSize.width / sourceSize.height
            return aspect >= 1 ? CGSize(width: long, height: long / aspect)
                               : CGSize(width: long * aspect, height: long)
        case .original:
            return sourceSize
        }
    }

    private static func crop(_ image: CIImage, normalized: CGRect, in size: CGSize) -> CIImage {
        let pixel = CGRect(x: (normalized.minX * size.width).rounded(),
                           y: (normalized.minY * size.height).rounded(),
                           width: max(1, (normalized.width * size.width).rounded()),
                           height: max(1, (normalized.height * size.height).rounded()))
        return image.cropped(to: pixel)
            .transformed(by: CGAffineTransform(translationX: -pixel.minX, y: -pixel.minY))
    }

    /// Exact-dimension scale. Lives in `ExportPipeline` now — every exporter
    /// needs the same one, and a rounding fix has to land for all of them.
    private static func scale(_ image: CIImage, to size: CGSize) -> CIImage {
        ExportPipeline.scale(image, to: size)
    }

    private static func scaleAspectFit(_ image: CIImage, into size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let factor = min(size.width / extent.width, size.height / extent.height)
        let fitted = CGSize(width: max(1, (extent.width * factor).rounded()),
                            height: max(1, (extent.height * factor).rounded()))
        let scaled = Self.scale(image, to: fitted)
        let dx = ((size.width - fitted.width) / 2).rounded()
        let dy = ((size.height - fitted.height) / 2).rounded()
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }

    private static func composite(_ image: CIImage, overMatte shade: MatteShade,
                                  targetSize: CGSize) -> CIImage {
        let color: CIColor = shade == .black ? .black : .white
        let matte = CIImage(color: color).cropped(to: CGRect(origin: .zero, size: targetSize))
        return image.composited(over: matte).cropped(to: CGRect(origin: .zero, size: targetSize))
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double,
                                   job: Job, sourceProps: [String: Any]) throws -> Data {
        guard let mutableData = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw RenderError.encodeFailed }
        var properties: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: quality]
        if job.includeEXIF,
           let merged = ExportMetadata.outputProperties(source: sourceProps as CFDictionary,
                                                        includeLocation: job.includeLocation) as? [String: Any] {
            properties.merge(merged) { _, new in new }
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.encodeFailed }
        return mutableData as Data
    }

    /// The five invariants X's documented no-recompress rule requires. All are
    /// checked before the file is written — an export that can't meet them fails
    /// that file rather than quietly shipping a recompressible one.
    static func verifyXInvariants(data: Data, pixelSize: CGSize) throws {
        guard pixelSize.width <= CGFloat(xMaxDimension), pixelSize.height <= CGFloat(xMaxDimension) else {
            throw RenderError.xInvariantFailed("dimensions exceed 4096")
        }
        guard data.count < xMaxBytes else { throw RenderError.xInvariantFailed("bytes ≥ 5 MB") }
        guard Double(data.count) < Double(pixelSize.width * pixelSize.height) else {
            throw RenderError.xInvariantFailed("bytes ≥ width × height")
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else { throw RenderError.xInvariantFailed("undecodable output") }
        guard props[kCGImagePropertyOrientation as String] == nil else {
            throw RenderError.xInvariantFailed("orientation tag present")
        }
        guard (props[kCGImagePropertyHasAlpha as String] as? Bool) != true else {
            throw RenderError.xInvariantFailed("alpha present")
        }
    }

    /// The EditCopyNaming-style collision ladder: `<stem>-<preset.id>.jpg`, then
    /// `-2`, `-3`… Lives in `ExportPipeline` now — never-overwrite is a rule
    /// every export path holds, so it gets one implementation.
    private static func collisionSafeURL(base: String, ext: String, in directory: URL) -> URL {
        ExportPipeline.collisionSafeURL(base: base, ext: ext, in: directory)
    }
}
