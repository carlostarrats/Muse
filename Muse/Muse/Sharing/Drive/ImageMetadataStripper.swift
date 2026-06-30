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
//  Strategy (every accepted output is VERIFIED clean — we never trust that
//  ImageIO honored a strip; see isClean):
//   - SINGLE-FRAME images re-encode from decoded pixels. A fresh CGImage carries
//     NO source metadata (no EXIF/GPS/XMP, no embedded thumbnail, no maker note,
//     no MPF second image), so the result is clean BY CONSTRUCTION — this
//     sidesteps every "did ImageIO actually honor the kCFNull?" trust question
//     that a lossless container-rewrite raises (those fail-opens are real for
//     HEIC/PNG/TIFF). Same format when writable (PNG re-encode is lossless and
//     keeps alpha; JPEG/HEIC take a modest, invisible-in-practice recompression),
//     else JPEG (which also makes RAW Google-thumbnailable). Recipients view
//     Google thumbnails, so the recompression is not user-visible in normal use.
//   - MULTI-FRAME images (animated GIF/APNG, multi-page) take a LOSSLESS path
//     instead (re-encoding would collapse them to a still): copy every frame,
//     null the private dicts per frame, keep only the animation-timing container
//     dicts. Accepted ONLY if isClean passes; if it doesn't, fall through to the
//     re-encode (losing animation but staying clean — rare).
//   - If no path yields provably-clean bytes, THROW — fail closed, never upload
//     an un-stripped or unverifiable original.
//
//  The verifier (isClean) checks BOTH the ImageIO property view (field-level, so
//  benign technical EXIF/TIFF like orientation/pixel-dimensions don't false-trip)
//  AND the raw bytes for metadata markers (XMP packets, PNG text chunks) — because
//  for container-item formats ImageIO can normalize the property view to look
//  clean while the bytes still carry the data.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageMetadataStripper {

    struct Output {
        let data: Data
        /// Reflects the ACTUAL encoded format (derived from the bytes), not the
        /// caller's extension-guess — and may change to image/jpeg when a
        /// non-writable source (RAW) is re-encoded. The caller uploads with this.
        let mime: String
    }

    enum StripError: Error { case notAnImage, encodeFailed }

    // MARK: dictionaries

    /// Every metadata dictionary nulled on the lossless path. Removes EXIF (incl.
    /// MakerNote), GPS, TIFF, IPTC, the per-format and maker dicts — without
    /// recompressing pixels. (JFIF density is harmless and left alone.)
    private static let metadataDicts: [CFString] = [
        kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary,
        kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary,
        kCGImagePropertyIPTCDictionary, kCGImagePropertyPNGDictionary,
        kCGImagePropertyGIFDictionary, kCGImagePropertyHEICSDictionary,
        kCGImagePropertyWebPDictionary, kCGImagePropertyDNGDictionary,
        kCGImagePropertyRawDictionary, kCGImagePropertyCIFFDictionary,
        kCGImageProperty8BIMDictionary,
        kCGImagePropertyMakerAppleDictionary, kCGImagePropertyMakerCanonDictionary,
        kCGImagePropertyMakerNikonDictionary, kCGImagePropertyMakerFujiDictionary,
        kCGImagePropertyMakerOlympusDictionary, kCGImagePropertyMakerPentaxDictionary,
        kCGImagePropertyMakerMinoltaDictionary,
    ]

    /// Animation-timing dicts that must SURVIVE on multi-frame images (else the
    /// animation breaks). Any private text they also carry is caught by isClean's
    /// byte scan, which forces a (still) re-encode.
    private static let animationDicts: [CFString] = [
        kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyHEICSDictionary,
    ]

    /// Dictionaries whose mere presence in the OUTPUT means private data survived.
    /// NOTE: Exif and TIFF are deliberately NOT here — ImageIO legitimately
    /// re-adds a benign technical Exif/TIFF block on encode (pixel dimensions,
    /// color space, orientation, resolution) when we write orientation, so we
    /// check those two dicts at the FIELD level instead (see hasPrivate). The
    /// dicts below are pure-metadata: any presence = a leak. (GIF/PNG/HEICS are
    /// animation dicts, vetted via the byte scan; ExifAux holds only lens/flash
    /// optics, not identity, but we still treat its identity-free contents as
    /// non-private — it's dropped on the lossless path regardless.)
    private static let forbiddenInOutput: [CFString] = [
        kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
        kCGImagePropertyDNGDictionary, kCGImagePropertyRawDictionary,
        kCGImagePropertyCIFFDictionary, kCGImageProperty8BIMDictionary,
        kCGImagePropertyMakerAppleDictionary, kCGImagePropertyMakerCanonDictionary,
        kCGImagePropertyMakerNikonDictionary, kCGImagePropertyMakerFujiDictionary,
        kCGImagePropertyMakerOlympusDictionary, kCGImagePropertyMakerPentaxDictionary,
        kCGImagePropertyMakerMinoltaDictionary,
    ]

    /// Identifying TIFF fields (camera + authorship + capture time). Orientation,
    /// X/YResolution, ResolutionUnit are technical and allowed.
    private static let identifyingTIFFKeys: [CFString] = [
        kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware,
        kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright,
        kCGImagePropertyTIFFHostComputer,
    ]

    /// Private Exif fields (capture time, free text, serials, location). A clean
    /// re-encode may still carry technical Exif (PixelXDimension/ColorSpace/…),
    /// which is NOT private and must not trip the verifier.
    private static let privateExifKeys: [CFString] = [
        kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
        kCGImagePropertyExifUserComment, kCGImagePropertyExifMakerNote,
        kCGImagePropertyExifSubjectLocation, kCGImagePropertyExifCameraOwnerName,
        kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber,
        kCGImagePropertyExifImageUniqueID,
    ]

    // MARK: entry

    static func strip(url: URL, mime: String) throws -> Output {
        // mappedIfSafe avoids a full in-memory copy for large files.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let srcType = CGImageSourceGetType(src) else {
            throw StripError.notAnImage
        }
        let imgProps = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = (imgProps?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        // Mime from the ACTUAL bytes, not the caller's extension guess.
        let actualMime = UTType(srcType as String)?.preferredMIMEType ?? mime

        // Multi-frame (animation): try the lossless path FIRST, since re-encoding
        // would collapse the animation to a still. Accepted only if VERIFIED clean
        // (animated images carrying private metadata are rare; if one does, we'd
        // rather lose the animation than leak). Single-frame images skip straight
        // to re-encode — it's clean by construction (a fresh CGImage carries NO
        // source metadata: no EXIF/GPS/XMP, no embedded thumbnail, no maker note,
        // no MPF second image), which sidesteps every "did ImageIO actually honor
        // the null?" trust question. Recipients view Google thumbnails anyway, so
        // the modest recompression is invisible in normal use.
        if CGImageSourceGetCount(src) > 1,
           let out = losslessStrip(src: src, type: srcType, orientation: orientation), isClean(out) {
            return Output(data: out, mime: actualMime)
        }
        // Re-encode from decoded pixels (clean by construction) — still verified.
        if let re = reencode(src: src, sourceType: srcType, orientation: orientation), isClean(re.data) {
            return re
        }
        // Fail closed — never upload an un-verified original.
        throw StripError.encodeFailed
    }

    // MARK: lossless path

    private static func losslessStrip(src: CGImageSource, type: CFString, orientation: UInt32) -> Data? {
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type, count, nil) else { return nil }

        if count > 1 {
            // Multi-frame: keep ONLY the animation-timing container dicts (loop
            // count etc.) — NOT the whole container bag, which can carry
            // container-level EXIF/TIFF/IPTC/maker on HEIC/TIFF.
            if let container = CGImageSourceCopyProperties(src, nil) as? [CFString: Any] {
                var safe: [CFString: Any] = [:]
                for k in animationDicts { if let v = container[k] { safe[k] = v } }
                if safe.isEmpty == false { CGImageDestinationSetProperties(dest, safe as CFDictionary) }
            }
            let opts = stripOptions(orientation: orientation, keepAnimation: true)
            for i in 0..<count { CGImageDestinationAddImageFromSource(dest, src, i, opts as CFDictionary) }
        } else {
            let opts = stripOptions(orientation: orientation, keepAnimation: false)
            CGImageDestinationAddImageFromSource(dest, src, 0, opts as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        let result = out as Data
        // Guard against silently-dropped frames (an ignored per-frame add failure):
        // if the output lost frames, reject so the re-encode fallback runs.
        if count > 1, let chk = CGImageSourceCreateWithData(result as CFData, nil),
           CGImageSourceGetCount(chk) != count { return nil }
        return result
    }

    private static func stripOptions(orientation: UInt32, keepAnimation: Bool) -> [CFString: Any] {
        var options: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImageMetadataShouldExcludeXMP: kCFBooleanTrue as Any,
            kCGImageMetadataShouldExcludeGPS: kCFBooleanTrue as Any,
            kCGImageDestinationEmbedThumbnail: kCFBooleanFalse as Any,   // no IFD1 thumbnail
        ]
        for key in metadataDicts { options[key] = kCFNull }
        if keepAnimation {
            for key in animationDicts { options.removeValue(forKey: key) }
        }
        return options
    }

    // MARK: re-encode path (clean by construction)

    private static func reencode(src: CGImageSource, sourceType: CFString, orientation: UInt32) -> Output? {
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0,
                [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let jpeg = UTType.jpeg.identifier as CFString
        // Prefer the source format (keeps PNG alpha etc.); JPEG covers RAW/unwritable.
        for type in [sourceType, jpeg] {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { continue }
            var opts: [CFString: Any] = [
                kCGImagePropertyOrientation: orientation,
                kCGImageDestinationEmbedThumbnail: kCFBooleanFalse as Any,
            ]
            if type == jpeg { opts[kCGImageDestinationLossyCompressionQuality] = 0.92 }
            CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { continue }
            let mime = UTType(type as String)?.preferredMIMEType ?? "image/jpeg"
            return Output(data: out as Data, mime: mime)
        }
        return nil
    }

    // MARK: verifier

    /// True only if `data` carries no private metadata. Checks BOTH the property
    /// view and the raw bytes (ImageIO can normalize the property view clean while
    /// the bytes still carry metadata, e.g. HEIC items / PNG chunks / XMP packets).
    static func isClean(_ data: Data) -> Bool {
        // Byte markers (format-scoped to avoid false positives in pixel data).
        let always: [String] = [
            "http://ns.adobe.com/xap/1.0/",        // XMP packet namespace
            "http://ns.adobe.com/xmp/extension/",  // extended (multi-segment) XMP
        ]
        for m in always where data.range(of: Data(m.utf8)) != nil { return false }
        // NOTE: we deliberately do NOT scan for the "Exif\0\0" APP1 marker — a
        // clean image legitimately carries an EXIF block holding only the
        // orientation + technical fields. Private EXIF content is caught at the
        // field level below (privateExifKeys) and via the per-format needle tests.
        // PNG metadata chunks — only meaningful when the output IS a PNG, and the
        // 4-byte names sit in chunk headers, so scope the scan to PNG bytes to
        // avoid coincidental hits in other formats' pixel data.
        // tEXt/zTXt/iTXt carry free-text (author/software/comment/XMP). NOT eXIf —
        // a clean PNG legitimately carries an eXIf chunk holding only orientation;
        // any GPS inside it is caught by the GPS-dict property check below.
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            for chunk in ["tEXt", "zTXt", "iTXt"] where data.range(of: Data(chunk.utf8)) != nil { return false }
        }

        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let count = max(1, CGImageSourceGetCount(src))
        if let container = CGImageSourceCopyProperties(src, nil) as? [CFString: Any],
           hasPrivate(container) { return false }
        for i in 0..<count {
            if let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
               hasPrivate(p) { return false }
        }
        // NOTE: we do NOT reject mere embedded-thumbnail PRESENCE — ImageIO
        // re-derives a clean thumbnail from the (already-stripped) pixels, which
        // is not a leak. The privacy risk is an OLD thumbnail carrying its own
        // GPS/content; the strip drops that via kCGImageDestinationEmbedThumbnail
        // = false on both paths (verified by testStripRemovesEmbeddedThumbnail).
        return true
    }

    private static func hasPrivate(_ props: [CFString: Any]) -> Bool {
        for k in forbiddenInOutput where props[k] != nil { return true }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            for k in identifyingTIFFKeys where tiff[k] != nil { return true }
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            for k in privateExifKeys where exif[k] != nil { return true }
        }
        return false
    }
}
