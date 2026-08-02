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
        guard let cgImage = ExportPipeline.context.createCGImage(
            image, from: extent,
            format: deep ? .RGBA16 : .RGBA8,
            colorSpace: sRGB)
        else { throw ExportPipeline.RenderError.encodeFailed }

        let data = try encode(cgImage, format: format, job: job,
                              sourceProperties: sourceProperties)

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
        try data.write(to: dest, options: .atomic)
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
    private static func encode(_ image: CGImage, format: ExportFormat, job: Job,
                               sourceProperties: [String: Any]) throws -> Data {
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
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportPipeline.RenderError.encodeFailed
        }
        return mutable as Data
    }
}
