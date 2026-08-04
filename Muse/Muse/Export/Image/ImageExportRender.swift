//
//  ImageExportRender.swift
//  Muse
//
//  The general export pipeline. Same discipline as SocialRender — the ORDER is
//  code, never data:
//
//    1  OutputRender.forOutput   — the choke point FIRST, so edits ride out
//    2  budget gate + oriented decode — orientation BAKED, so no output tag
//    3  resize                   — never upscales
//    4  flatten, but only for containers with no usable alpha
//    5  encode at the chosen format / quality / depth, sRGB
//    6  verify clean when metadata is off, then write without overwriting
//
//  It deliberately does NOT sharpen, the one divergence from SocialRender. A
//  social export is being FITTED to a platform, and unsharp masking undoes the
//  resampling softness that fitting causes. A general export is a faithful
//  conversion, and a sharpening pass nobody asked for is a surprise in someone
//  else's pixels. darktable doesn't sharpen on export either.
//
//  Platform-neutral: Foundation / CoreGraphics / CoreImage / ImageIO only.
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// `nonisolated`: exports render off-main.
nonisolated enum ImageExportRender {
    struct Job: Sendable {
        /// The ORIGINAL library URL — `forOutput` resolves any edit stack.
        var sourceURL: URL
        var settings: ExportSettings

        init(sourceURL: URL, settings: ExportSettings) {
            self.sourceURL = sourceURL
            self.settings = settings
        }
    }

    struct Result: Sendable {
        let url: URL
        let pixelSize: CGSize
        let bytes: Int
    }

    static func export(_ job: Job, to directory: URL) throws -> Result {
        let format = job.settings.format.resolved(for: job.sourceURL)

        // 0. A faithful copy beats a re-encode.
        //
        //    When nothing is being CHANGED — no edit stack, no resize, no
        //    format conversion, metadata kept — the most correct output is the
        //    original bytes. Re-encoding them was destroying the gain map of a
        //    file Muse had only been asked to copy, and it is also the only way
        //    an HDR photo survives on macOS 14.6, where writing a gain map is
        //    unavailable. Strictly more faithful for SDR files too.
        //    It STILL goes through the choke point. `forOutput` is an identity
        //    for an unedited file, so the bytes copied are the user's own —
        //    but taking the source from `RenderedOutput` rather than from the
        //    raw URL is what keeps "everything that leaves the app goes
        //    through OutputRender" structurally true. If the guard below is
        //    ever loosened by mistake, an edited file gets its RENDER copied
        //    rather than its unedited original.
        if job.settings.format == .sameAsOriginal,
           job.settings.resize == .original,
           job.settings.includeEXIF,
           job.settings.includeLocation,
           EditStackIndex.resolvedStack(for: job.sourceURL) == nil {
            let passthrough = try OutputRender.forOutput(job.sourceURL)
            defer { OutputRender.discard(passthrough) }
            let dest = ExportPipeline.collisionSafeURL(
                base: job.sourceURL.deletingPathExtension().lastPathComponent,
                ext: job.sourceURL.pathExtension,
                in: directory)
            try FileManager.default.copyItem(at: passthrough.url, to: dest)
            let size = (try? ExportPipeline.headerSize(url: dest)) ?? .zero
            let attributes = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let bytes = (attributes?[.size] as? Int) ?? 0
            return Result(url: dest, pixelSize: size, bytes: bytes)
        }

        // 1. Choke point. A 16-bit request renders its temp at 16-bit rather
        //    than inflating an 8-bit one and calling it deep.
        let preferred: OutputFormat? = (format == .tiff && job.settings.tiff16) ? .tiff16 : nil
        let out = try OutputRender.forOutput(job.sourceURL, preferring: preferred)
        // The render temp exists only to be decoded below; collect it here
        // rather than leaving it for the 24 h launch sweep. No-op for an
        // unedited source (nothing was rendered).
        defer { OutputRender.discard(out) }

        // 2. Budget gate on the header, then a bounded decode. Reading the
        //    header first is what lets the decode ceiling be chosen from the
        //    OUTPUT size — decoding 40 MP to write 1000px wastes both.
        //
        //    This path carries 16-bit correctly, which is worth stating because
        //    it looks like it shouldn't: `CGImageSourceCreateThumbnailAtIndex`
        //    is usually an 8-bit API, but it preserves the source's depth —
        //    verified, a 16-bit TIFF decodes to bitsPerComponent 16 through it,
        //    and `testSixteenBitTIFFPreservesSubEightBitDetail` pins that.
        //    Don't "fix" this with a full-depth `CIImage(contentsOf:)`: that
        //    ignores the decode ceiling and would materialise the whole raster
        //    no matter how small the export.
        let headerSize = try ExportPipeline.headerSize(url: out.url)
        let deep = (format == .tiff && job.settings.tiff16)
        let planned = job.settings.resize.targetSize(for: headerSize)
        let source = try ExportPipeline.load(
            url: out.url,
            decodeLongEdgeMax: Int(max(1, max(planned.width, planned.height).rounded())))
        var image = CIImage(cgImage: source.image)
        let sourceProperties = source.sourceProperties
        var decodedSize = source.decodedSize

        // 3. Resize. Recomputed against what actually DECODED: the ImageIO
        //    ceiling can land a pixel or two off on odd ratios, and the output
        //    dimensions have to be exact.
        let finalSize = job.settings.resize.targetSize(for: decodedSize)
        if finalSize != decodedSize {
            image = ExportPipeline.scale(image, to: finalSize)
            decodedSize = finalSize
        }

        // 4. Background. Transparency survives only when the user asked for it
        //    AND the container can carry it; otherwise the picture is
        //    composited onto the chosen colour. A JPEG has to land on
        //    something, and an uncomposited alpha channel lands on black.
        let extent = image.extent.integral
        guard extent.width >= 1, extent.height >= 1 else {
            throw ExportPipeline.RenderError.encodeFailed
        }
        if job.settings.flattens(for: format) {
            let color: CIColor = job.settings.flattenColor(for: format) == .black ? .black : .white
            image = image.composited(over: CIImage(color: color).cropped(to: extent))
        }

        // 5. Encode. sRGB throughout — converting wide-gamut RAW here is what
        //    makes an export look the same wherever it lands.
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ExportPipeline.RenderError.encodeFailed
        }
        //    HDR follows the FORMAT the user already picked — no separate
        //    toggle. PNG, JPEG, TIFF and WebP cannot carry a gain map at all,
        //    so they are SDR by construction; HEIC is the only place the
        //    choice exists. Anything landing in SDR is TONE-MAPPED on the way,
        //    never clipped.
        let headroom = EditRenderer.sourceHeadroom(url: job.sourceURL)
        let wantsHDR = Self.wantsHDR(headroom: headroom, format: format)
        if !wantsHDR {
            image = HDRDecode.toneMappedToSDR(image, headroom: headroom)
        }
        guard let cgImage = ExportPipeline.context.createCGImage(
            image, from: extent,
            format: (wantsHDR || deep) ? .RGBA16 : .RGBA8,
            colorSpace: wantsHDR ? HDRDecode.hdrColorSpace : sRGB)
        else { throw ExportPipeline.RenderError.encodeFailed }

        let data = try encode(cgImage, format: format, job: job,
                              sourceProperties: sourceProperties, writesHDR: wantsHDR)

        // 6. Verify, then write. A metadata-off output must be PROVABLY clean,
        //    not merely constructed to be — the same rule the social and Drive
        //    paths hold.
        if job.settings.includeEXIF == false {
            guard ImageMetadataStripper.isClean(data) else {
                throw ExportPipeline.RenderError.verifyFailed
            }
        }
        let stem = job.sourceURL.deletingPathExtension().lastPathComponent
        let dest = ExportPipeline.collisionSafeURL(
            base: stem,
            ext: job.settings.format.fileExtension(for: job.sourceURL),
            in: directory)
        // `.withoutOverwriting`, NOT `.atomic`. `collisionSafeURL` picks a name
        // that did not exist a moment ago, but "a moment ago" is not a
        // guarantee — anything that lands at that path in between (a sync
        // client, another app, a second export into the same folder) would be
        // silently destroyed by an atomic write, which is precisely what
        // `collisionSafeURL`'s own comment promises can never happen. With this
        // flag the racing export FAILS and the user's existing file survives.
        //
        // Do NOT "improve" this to `[.atomic, .withoutOverwriting]` — Foundation
        // traps on that combination ("withoutOverwriting is not supported with
        // atomic"), so it would crash the app rather than harden it.
        try data.write(to: dest, options: .withoutOverwriting)
        return Result(url: dest,
                      pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
                      bytes: data.count)
    }

    /// A MEASURED size estimate for the current settings.
    ///
    /// It encodes the card's already-decoded preview at exactly the settings
    /// the export will use, then scales the result by the pixel-count ratio.
    /// That's a real measurement of a real encode rather than a
    /// bits-per-pixel guess — which matters, because a number in an interface
    /// gets believed, and the whole point of showing it is to let someone
    /// trade quality against size before committing.
    ///
    /// Scaling by pixel count is where the approximation lives: compressed
    /// size is very nearly linear in pixels at a fixed quality for photographic
    /// content, and the readout is prefixed "≈" because "very nearly" isn't
    /// "exactly". Returns nil rather than a bad guess if the encode fails.
    static func estimatedBytes(preview: CGImage, settings: ExportSettings,
                               for sourceURL: URL, outputPixelCount: Double) -> Int? {
        let format = settings.format.resolved(for: sourceURL)
        let previewPixels = Double(preview.width * preview.height)
        guard previewPixels > 0, outputPixelCount > 0 else { return nil }

        // TIFF is the one format that needs no encode: ImageIO writes it
        // uncompressed, so the size is arithmetic and exact.
        if format == .tiff {
            let bytesPerPixel = settings.tiff16 ? 8.0 : 4.0
            return Int(outputPixelCount * bytesPerPixel)
        }
        let job = Job(sourceURL: sourceURL, settings: settings)
        guard let data = try? encode(preview, format: format, job: job,
                                     sourceProperties: [:]) else { return nil }
        return Int(Double(data.count) * (outputPixelCount / previewPixels))
    }

    /// WebP goes through our own encoder; everything else through ImageIO.
    /// Whether this export writes a real HDR file.
    ///
    /// macOS 14.6 COULD write PQ here, and deliberately does not: a PQ file
    /// looks wrong on an ordinary SDR display, whereas a gain-map file degrades
    /// gracefully. Shipping something that looks broken everywhere else is
    /// worse than shipping an SDR photo, so on the floor this stays off and the
    /// image tone-maps instead.
    static func wantsHDR(headroom: CGFloat, format: ExportFormat) -> Bool {
        guard headroom > HDRDecode.hdrThreshold, format == .heic else { return false }
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private static func encode(_ image: CGImage, format: ExportFormat, job: Job,
                               sourceProperties: [String: Any],
                               writesHDR: Bool = false) throws -> Data {
        if format == .webp {
            return try WebPEncoder.encode(image, quality: job.settings.quality,
                                          lossless: job.settings.webpLossless)
        }
        let type = format.utType(for: job.sourceURL).identifier as CFString
        guard let mutable = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(mutable, type, 1, nil)
        else { throw ExportPipeline.RenderError.encodeFailed }

        var properties: [String: Any] = [:]
        if format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality as String] = job.settings.quality
        }
        if job.settings.includeEXIF,
           let merged = ExportMetadata.outputProperties(
                source: sourceProperties as CFDictionary,
                includeLocation: job.settings.includeLocation) as? [String: Any] {
            properties.merge(merged) { _, new in new }
        }
        // The gain map is what makes an HDR export ALSO look right on an
        // ordinary display — a bare PQ file does not.
        if writesHDR, #available(macOS 15.0, *) {
            properties[kCGImageDestinationEncodeRequest as String] =
                kCGImageDestinationEncodeToISOGainmap
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportPipeline.RenderError.encodeFailed
        }
        return mutable as Data
    }
}
