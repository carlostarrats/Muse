//
//  HDRDecode.swift
//  Muse
//
//  The ONE place that knows how to read an HDR photo.
//
//  iPhone gain-map HEIC is the default capture format, so this is the most
//  common file a Muse user owns. Before this file existed every decode path
//  asked ImageIO for an 8-bit sRGB raster, and the headroom was gone before any
//  other code could see it — the photo displayed flat and exported flatter.
//
//  Why a seam rather than options at each call site: there are five decode
//  entry points (grid thumbnail, hero, edit renderer, export, analysis) and a
//  sixth would have been added without the HDR request. Routing them through
//  one function means "does Muse understand HDR" has exactly one answer.
//
//  Measured, not assumed. A 4.0 linear pixel written four ways and read back
//  through `kCGImageSourceDecodeToHDR`:
//
//      PNG  8-bit sRGB          -> 1.0   (hard clip)     323 B
//      PNG 16-bit linear sRGB   -> 1.0   (hard clip)     779 B
//      PNG 16-bit PQ            -> 4.00  (intact)      5,138 B
//      HEIC 10-bit PQ           -> 4.02  (intact)        491 B
//
//  Two things follow. Container is not the constraint — bit depth and colour
//  space are; PNG holds HDR fine at 16-bit PQ. And 8-bit sRGB HARD-CLIPS
//  rather than tone-mapping, so 2.0 and 4.0 both land on 1.0 and every
//  specular highlight becomes one flat white blob. That is why every HDR->SDR
//  conversion in Muse goes through `toneMappedToSDR` instead of letting
//  `createCGImage` clamp.
//
//  Platform-neutral: Foundation / CoreGraphics / CoreImage / ImageIO only.
//

import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// How far above SDR white a file's pixels reach. 1.0 is an ordinary photo.
nonisolated struct HDRInfo: Equatable, Sendable {
    let headroom: CGFloat

    /// Compared with slack rather than `> 1.0`: a file that declares a
    /// headroom of 1.0000001 is an SDR photo with float noise, and treating it
    /// as HDR would push it down the deep-render path for nothing.
    var isHDR: Bool { headroom > HDRDecode.hdrThreshold }

    static let sdr = HDRInfo(headroom: 1.0)
}

nonisolated enum HDRDecode {

    /// Anything at or below this is an ordinary photo.
    static let hdrThreshold: CGFloat = 1.0001

    /// PQ, because it is the only extended-range space that survived a
    /// write/read round-trip in every container tested. Extended LINEAR sRGB
    /// looks like it should work and does not — a 4.0 pixel written to a
    /// 16-bit linear PNG reads back as 1.0 (measured, see the table above).
    static let hdrColorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
    static let sdrColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// What a gain map is worth when the file carries one but declares no
    /// headroom value. Conservative on purpose: treating a real gain map as
    /// SDR is the failure this whole file exists to prevent, and 4.0 (two
    /// stops) is roughly what an iPhone capture actually holds.
    static let assumedGainMapHeadroom: CGFloat = 4.0

    // MARK: - Inspect

    /// Header-only. Never decodes, so the grid can ask "is this HDR" for every
    /// tile in a folder without paying for a raster.
    static func info(url: URL) -> HDRInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return .sdr }
        return info(source: source)
    }

    static func info(source: CGImageSource) -> HDRInfo {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else { return .sdr }
        return info(properties: props)
    }

    /// Split out from the source so it is a pure function over a dictionary —
    /// testable without a file, and reusable by any caller that already read
    /// the properties (the thumbnail path reads them for the decode budget, so
    /// HDR detection there costs nothing extra).
    static func info(properties props: [CFString: Any]) -> HDRInfo {
        // ImageIO exposes the file's own headroom on a gain-map capture. It is
        // not a published constant, so it is read defensively and by name —
        // but when present it is both CHEAPER and more accurate than the
        // alternative. Measured on a real iPhone HEIC: this dictionary read is
        // ~1 ms while `CGImageSourceCopyAuxiliaryDataInfoAtIndex` is ~3 ms
        // (it copies the actual gain-map bytes), and the true value was 8.0
        // where the aux probe could only assume a flat 4.0. Reading it per
        // tile is what made the first cut of this expensive.
        if let n = props["Headroom" as CFString] as? NSNumber {
            let value = CGFloat(n.doubleValue)
            if value.isFinite, value > 1.0 { return HDRInfo(headroom: value) }
        }
        // No headroom declared, but the base image may itself be PQ or HLG.
        if let profile = props[kCGImagePropertyProfileName] as? String,
           profile.contains("PQ") || profile.contains("HLG") || profile.contains("2100") {
            return HDRInfo(headroom: assumedGainMapHeadroom)
        }
        // Deliberately NOT falling back to an auxiliary-data probe. A gain-map
        // file that declares no headroom would be treated as SDR — which is
        // exactly what Muse did before any of this, so the failure mode is
        // "no HDR", never a wrong picture, and it isn't worth 3 ms on every
        // tile in the grid to chase.
        return .sdr
    }

    // MARK: - Decode

    /// HDR-aware decode. `maxPixel == 0` means full resolution.
    /// Returns nil for an unreadable file or one that busts the decode budget.
    ///
    /// The budget check lives HERE rather than at each call site, so a new
    /// caller cannot forget it — this is an automatic (no-click) decode path
    /// like every other one the 300 MP guard covers.
    static func decode(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              ThumbnailCache.withinDecodeBudget(source) else { return nil }
        return decode(source: source, maxPixel: maxPixel)
    }

    static func decode(source: CGImageSource, maxPixel: Int) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
        ]
        // BOTH rungs go through the thumbnail API, and that is deliberate.
        // `CGImageSourceCreateImageAtIndex` IGNORES
        // `kCGImageSourceCreateThumbnailWithTransform` — the key only applies
        // to the thumbnail call — so the full-resolution branch returned
        // photos SIDEWAYS. Measured on a 40×20 file tagged orientation 6: the
        // thumbnail rung gave 20×40 and the full rung gave 40×20. One function
        // with two contracts depending on an argument is exactly the kind of
        // thing the first full-res caller would have shipped as a bug.
        //
        // A ceiling at the source's own long edge is not a downscale, so
        // "full resolution" stays full resolution.
        options[kCGImageSourceThumbnailMaxPixelSize] =
            maxPixel > 0 ? maxPixel : fullResolutionCeiling(source: source)
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A ceiling at or above the source's own long edge, so the thumbnail API
    /// returns every pixel rather than downsampling.
    private static func fullResolutionCeiling(source: CGImageSource) -> Int {
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue {
            return max(w, h)
        }
        // Undeclared dimensions must not mean "no image". Matching
        // `withinDecodeBudget`, which ALLOWS a header it can't measure, this
        // falls back to a ceiling no real photo reaches — the decode budget
        // caps at 300 MP, whose long edge is ~17k even before aspect. The
        // thumbnail API never upsamples, so an over-large ceiling is simply
        // "full size".
        return 1_000_000
    }

    // MARK: - Tone map

    /// HDR -> SDR without blowing the highlights.
    ///
    /// A bare `createCGImage(format: .RGBA8, colorSpace: sRGB)` HARD-CLIPS.
    /// Every deliberate downconversion in Muse goes through here instead, so
    /// "how does Muse flatten an HDR photo" has one answer and one test.
    static func toneMappedToSDR(_ image: CIImage, headroom: CGFloat) -> CIImage {
        guard headroom > hdrThreshold else { return image }

        if #available(macOS 15.0, *) {
            let filter = CIFilter.toneMapHeadroom()
            filter.inputImage = image
            filter.sourceHeadroom = Float(headroom)
            filter.targetHeadroom = 1.0
            if let output = filter.outputImage { return output }
        }
        return reinhardRollOff(image, headroom: headroom)
    }

    /// The macOS 14.6 path. `CIToneMapHeadroom` is 15.0-only, so the
    /// highlights roll off through a Reinhard curve instead.
    ///
    /// Last-resort fallback if the kernel failed to load: a linear divide.
    /// It darkens midtones badly, which is why it isn't the primary — but it
    /// keeps every value ORDERED and unclipped, and a dim photo is recoverable
    /// where a clipped one is not.
    private static func reinhardRollOff(_ image: CIImage, headroom: CGFloat) -> CIImage {
        let h = Float(max(headroom, hdrThreshold))
        if let kernel = EditKernels.reinhardToneMap,
           let output = kernel.apply(extent: image.extent, arguments: [image, h]) {
            return output
        }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        let s = 1.0 / h
        filter.rVector = CIVector(x: CGFloat(s), y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: CGFloat(s), z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: CGFloat(s), w: 0)
        return filter.outputImage ?? image
    }
}
