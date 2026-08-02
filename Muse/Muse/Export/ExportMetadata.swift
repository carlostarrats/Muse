//
//  ExportMetadata.swift
//  Muse
//
//  Output metadata policy for every export. Moved up out of Export/Social/
//  when the general image export needed the same policy — a photograph's EXIF
//  rules don't change because of which button started the export.
//
//  The DEFAULT (EXIF toggle off) writes no source properties at all — that path
//  lives in the renderers, which build a fresh properties dict carrying only the
//  compression quality and then VERIFY the encoded bytes with
//  ImageMetadataStripper.isClean (verify, don't trust construction — the same
//  rule the Drive share strip follows).
//
//  This file covers ONLY the EXIF-on case: copy
//  camera/lens/exposure (EXIF + TIFF) and creator/copyright (IPTC), ALWAYS drop
//  orientation keys / thumbnail-preview dicts / maker notes, and drop GPS unless
//  the separate `includeLocation` opt-in is set — that sub-toggle defaults off
//  and is never remembered.
//

import ImageIO

// `nonisolated`: builds export properties on the off-main render task.
nonisolated enum ExportMetadata {
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
