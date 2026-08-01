//
//  SocialMetadata.swift
//  Muse
//
//  Output metadata policy for social export.
//
//  The DEFAULT (EXIF toggle off) writes no source properties at all — that path
//  lives in SocialRender, which builds a fresh properties dict carrying only the
//  compression quality and then VERIFIES the encoded bytes with
//  ImageMetadataStripper.isClean (verify, don't trust construction — the same
//  rule the Drive share strip follows).
//
//  This file covers ONLY the EXIF-on case (photography platforms): copy
//  camera/lens/exposure (EXIF + TIFF) and creator/copyright (IPTC), ALWAYS drop
//  orientation keys / thumbnail-preview dicts / maker notes, and drop GPS unless
//  the separate `includeLocation` opt-in is set — that sub-toggle defaults off
//  and is never remembered.
//

import ImageIO

enum SocialMetadata {
    static func outputProperties(source: CFDictionary, includeLocation: Bool) -> CFDictionary {
        var out: [String: Any] = [:]
        let src = source as? [String: Any] ?? [:]

        if var exif = src[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifSubjectLocation as String)
            exif.removeValue(forKey: kCGImagePropertyExifMakerNote as String)
            out[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = src[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            // Orientation is ALWAYS dropped — pixels are baked at decode, so an
            // orientation tag surviving here would double-rotate the output.
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation as String)
            out[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if let iptc = src[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
            out[kCGImagePropertyIPTCDictionary as String] = iptc
        }
        if includeLocation, let gps = src[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            out[kCGImagePropertyGPSDictionary as String] = gps
        }
        // The top-level orientation key, thumbnail/preview dictionaries and
        // maker-note dictionaries are never copied — they simply aren't read
        // out of `src` above.
        return out as CFDictionary
    }
}
