//
//  ExportPipeline.swift
//  Muse
//
//  The render steps every export path shares. Extracted from SocialRender when
//  the general image export needed the same decode, scale and naming — one
//  copy, so a fix to the budget gate or the orientation bake can't land in one
//  exporter and miss the other.
//
//  Platform-neutral: Foundation / CoreGraphics / CoreImage / ImageIO only —
//  never AppKit. Same rule Export/Social/ holds.
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO

// `nonisolated`: every exporter renders off-main.
nonisolated enum ExportPipeline {
    enum RenderError: Error {
        case decodeFailed
        case tooLarge
        case encodeFailed
        case verifyFailed
    }

    /// One CIContext for every export in a run. Not the editor's live context —
    /// this one doesn't cache intermediates (each image is seen once).
    static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
        .cacheIntermediates: false,
    ])

    /// A decoded, display-oriented source plus the header facts a caller needs
    /// to reason about size before it looks at pixels.
    struct DecodedSource {
        let image: CGImage
        /// The decoded image's own size (orientation already applied).
        let decodedSize: CGSize
        /// The FULL source size, orientation applied — what "original size"
        /// means, and what never-upscale is measured against.
        let sourceSize: CGSize
        /// Raw header properties, for metadata merging at encode time.
        let sourceProperties: [String: Any]
    }

    /// Header-only size, orientation applied, for a caller that must choose a
    /// decode ceiling BEFORE decoding. Guards the decode budget too, so a
    /// dimension bomb is refused at the cheapest possible point.
    static func headerSize(url: URL) throws -> CGSize {
        let (_, _, size) = try readHeader(url: url)
        return size
    }

    /// Steps 2–3 of every export: bomb guard, then a bounded decode with the
    /// EXIF orientation BAKED IN (`…WithTransform`), so no output can carry an
    /// orientation tag.
    ///
    /// `decodeLongEdgeMax == nil` decodes at full source resolution.
    static func load(url: URL, decodeLongEdgeMax: Int?) throws -> DecodedSource {
        let (cgSource, properties, sourceSize) = try readHeader(url: url)
        let maxPixel = decodeLongEdgeMax ?? Int(max(sourceSize.width, sourceSize.height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(
            cgSource, 0, options as CFDictionary)
        else { throw RenderError.decodeFailed }
        return DecodedSource(image: decoded,
                             decodedSize: CGSize(width: decoded.width, height: decoded.height),
                             sourceSize: sourceSize,
                             sourceProperties: properties)
    }

    /// The budget gate plus the orientation-corrected header size. Shared by
    /// `headerSize` and `load` so the two can never disagree about how big a
    /// file is or whether it's safe to open.
    private static func readHeader(url: URL) throws -> (CGImageSource, [String: Any], CGSize) {
        guard let cgSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw RenderError.decodeFailed
        }
        // A few-KB file can declare enormous dimensions; this is the header-only
        // pre-check that keeps a full raster from being materialized.
        guard ThumbnailCache.withinDecodeBudget(cgSource) else { throw RenderError.tooLarge }
        guard let props = CGImageSourceCopyPropertiesAtIndex(cgSource, 0, nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int,
              let h = props[kCGImagePropertyPixelHeight as String] as? Int,
              w > 0, h > 0
        else { throw RenderError.decodeFailed }
        // The header reports STORED dimensions; an EXIF-rotated source decodes
        // transposed, so swap before anything reasons about aspect.
        let orientation = (props[kCGImagePropertyOrientation as String] as? UInt32) ?? 1
        let size = (5...8).contains(Int(orientation))
            ? CGSize(width: h, height: w)
            : CGSize(width: w, height: h)
        return (cgSource, props, size)
    }

    /// Exact-dimension scale. `CILanczosScaleTransform` alone lands a fraction
    /// of a pixel off on some ratios, so the result is cropped to the integral
    /// target — output dims must be EXACT (matte and crop alike).
    static func scale(_ image: CIImage, to size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scaleY = size.height / extent.height
        let scaleX = size.width / extent.width
        let scaled = image.applyingFilter("CILanczosScaleTransform",
            parameters: [kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: scaleX / scaleY])
        return scaled
            .transformed(by: CGAffineTransform(translationX: -scaled.extent.minX,
                                               y: -scaled.extent.minY))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// `<base>.<ext>`, then `-2`, `-3`… case-insensitively. Never returns a path
    /// that already exists, so an export can never overwrite a file the user
    /// already has — the one way this feature could destroy data.
    static func collisionSafeURL(base: String, ext: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var n = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
