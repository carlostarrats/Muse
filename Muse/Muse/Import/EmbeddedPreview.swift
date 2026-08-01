//
//  EmbeddedPreview.swift
//  Muse
//
//  The rendered preview another app already baked into the file.
//
//  For a Lightroom-imported photo this is the honest answer to "what did it
//  look like over there?" — Muse's approximation is directional, so being able
//  to hold it up against Adobe's own render is worth more than any amount of
//  reassurance in the report.
//
//  `ThumbnailFromImageIfAbsent: false` is the whole point: EMBEDDED BYTES
//  ONLY, never a primary decode. A RAW typically carries one; a plain JPEG
//  typically returns nil, and nil is a correct answer (the compare source is
//  simply not offered).
//

import Foundation
import ImageIO
import CoreGraphics

nonisolated enum EmbeddedPreview {

    static func image(for url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              ThumbnailCache.withinDecodeBudget(source) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
