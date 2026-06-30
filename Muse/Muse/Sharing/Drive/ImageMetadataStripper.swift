//
//  ImageMetadataStripper.swift
//  Muse
//
//  Drive-share privacy. Uploaded images are made anyone-with-link readable AND
//  their Drive file ids ride the (public) share URL, so a recipient can fetch
//  the ORIGINAL — not just the EXIF-stripped Google thumbnail shown on the page.
//  To make sure that original carries no private metadata (GPS coordinates,
//  capture timestamps, camera make/model/serial, software, IPTC, XMP, maker
//  notes, embedded thumbnails), every image is run through this stripper BEFORE
//  upload (see DriveClient.uploadFile).
//
//  Strategy, in order:
//   1. Lossless container rewrite (no pixel recompression) via
//      CGImageDestinationAddImageFromSource, nulling every metadata dictionary
//      and excluding XMP/GPS — keeping ONLY the display orientation (not private;
//      dropping it would rotate photos). Used when the source's own format is
//      writable by ImageIO (jpeg/png/heic/tiff/gif — the real cases).
//   2. Fallback: decode the pixels and re-encode a fresh JPEG carrying nothing
//      but the image + orientation. Covers types ImageIO can read but not write
//      back (e.g. camera RAW) — which also makes them Google-thumbnailable.
//   3. If the bytes can't be decoded as an image at all, THROW — fail closed,
//      never upload an un-stripped original.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageMetadataStripper {

    struct Output {
        let data: Data
        /// May differ from the input mime when a non-writable source (RAW) is
        /// re-encoded to JPEG in the fallback path; the caller uploads with this.
        let mime: String
    }

    enum StripError: Error { case notAnImage, encodeFailed }

    /// Every top-level metadata dictionary ImageIO exposes. Nulling these on
    /// AddImageFromSource removes EXIF (incl. MakerNote + embedded thumbnail),
    /// GPS, TIFF (make/model/software/datetime), IPTC, and the per-format aux
    /// dictionaries — without touching the encoded pixels.
    private static let metadataDicts: [CFString] = [
        kCGImagePropertyExifDictionary,
        kCGImagePropertyExifAuxDictionary,
        kCGImagePropertyGPSDictionary,
        kCGImagePropertyTIFFDictionary,
        kCGImagePropertyIPTCDictionary,
        kCGImagePropertyJFIFDictionary,
        kCGImagePropertyPNGDictionary,
        kCGImagePropertyGIFDictionary,
        kCGImagePropertyHEICSDictionary,
        kCGImagePropertyWebPDictionary,
        kCGImagePropertyDNGDictionary,
        kCGImagePropertyRawDictionary,
        kCGImagePropertyCIFFDictionary,
        kCGImagePropertyMakerAppleDictionary,
        kCGImagePropertyMakerCanonDictionary,
        kCGImagePropertyMakerNikonDictionary,
        kCGImagePropertyMakerFujiDictionary,
        kCGImagePropertyMakerOlympusDictionary,
        kCGImagePropertyMakerPentaxDictionary,
        kCGImagePropertyMakerMinoltaDictionary,
        kCGImageProperty8BIMDictionary,
    ]

    static func strip(url: URL, mime: String) throws -> Output {
        let data = try Data(contentsOf: url)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(src) != nil else {
            throw StripError.notAnImage
        }
        let srcType = CGImageSourceGetType(src)!
        let imgProps = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = (imgProps?[kCGImagePropertyOrientation] as? UInt32) ?? 1

        // 1) Lossless same-format strip when the source type is writable.
        if let out = losslessStrip(src: src, type: srcType, orientation: orientation) {
            return Output(data: out, mime: mime)
        }
        // 2) Fallback: re-encode the decoded pixels as a bare JPEG.
        if let jpeg = reencodeJPEG(src: src, orientation: orientation) {
            return Output(data: jpeg, mime: "image/jpeg")
        }
        // 3) Couldn't produce stripped output → fail closed.
        throw StripError.encodeFailed
    }

    private static func losslessStrip(src: CGImageSource, type: CFString,
                                      orientation: UInt32) -> Data? {
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type, count, nil) else { return nil }

        if count > 1 {
            // Multi-frame (animated GIF / APNG / animated HEIC): copy EVERY frame
            // so the animation isn't collapsed to a still, and preserve the
            // container-level timing (e.g. GIF loop count). Private dicts are
            // still nulled per frame; only the format dicts that carry animation
            // timing are kept (see keepAnimation).
            if let container = CGImageSourceCopyProperties(src, nil) as? [CFString: Any] {
                var cp = container
                cp[kCGImagePropertyGPSDictionary] = nil   // defensive; GPS isn't container-level
                CGImageDestinationSetProperties(dest, cp as CFDictionary)
            }
            let opts = stripOptions(orientation: orientation, keepAnimation: true)
            for i in 0..<count { CGImageDestinationAddImageFromSource(dest, src, i, opts as CFDictionary) }
        } else {
            let opts = stripOptions(orientation: orientation, keepAnimation: false)
            CGImageDestinationAddImageFromSource(dest, src, 0, opts as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Removal options: null every private metadata dict + exclude XMP/GPS, while
    /// re-asserting orientation (not private) so photos stay upright. On
    /// multi-frame images the animation-timing dicts (GIF/PNG/HEICS) are kept,
    /// or the animation would break.
    private static func stripOptions(orientation: UInt32, keepAnimation: Bool) -> [CFString: Any] {
        var options: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImageMetadataShouldExcludeXMP: kCFBooleanTrue as Any,
            kCGImageMetadataShouldExcludeGPS: kCFBooleanTrue as Any,
        ]
        for key in metadataDicts { options[key] = kCFNull }
        if keepAnimation {
            options.removeValue(forKey: kCGImagePropertyGIFDictionary)
            options.removeValue(forKey: kCGImagePropertyPNGDictionary)
            options.removeValue(forKey: kCGImagePropertyHEICSDictionary)
        }
        return options
    }

    private static func reencodeJPEG(src: CGImageSource, orientation: UInt32) -> Data? {
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0,
                [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        // Only the orientation + a high quality; no source metadata is carried.
        let options: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.92,
        ]
        CGImageDestinationAddImage(dest, cg, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
