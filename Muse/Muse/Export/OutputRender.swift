//
//  OutputRender.swift
//  Muse
//
//  Every path that ships pixels out of the app renders through here. Today it
//  is IDENTITY — originals pass through unrendered — so nothing about export or
//  sharing changes; Spec 04 renders the edit stack when one exists, in this one
//  place, and every call site is already correct.
//
//  `RenderedOutput`'s `fileprivate` init is the enforcement: it can only be
//  constructed inside this file, so a new export/share/publish path physically
//  cannot compile without going through `OutputRender`. That is the whole
//  point — the failure mode this prevents is an export silently shipping
//  unedited pixels because someone passed a bare URL.
//
//  Backup is the ONE deliberate exclusion: it restores originals by content
//  hash, and rendering edits into it would corrupt the restore. See
//  `Backup/BackupBuilder.swift`.
//

import Foundation
import CoreGraphics
import ImageIO

/// Bytes approved for leaving the app. The ONLY way to obtain one is
/// `OutputRender`.
struct RenderedOutput: Sendable {
    /// The file to read. The original today; a rendered temp file once an edit
    /// stack exists.
    let url: URL
    /// The edit stack these bytes were rendered from; nil = unedited original.
    let stackHash: String?

    fileprivate init(url: URL, stackHash: String?) {
        self.url = url
        self.stackHash = stackHash
    }
}

nonisolated enum OutputRender {

    static func forOutput(_ url: URL) throws -> RenderedOutput {
        RenderedOutput(url: url, stackHash: EditStackIndex.stackHash(for: url))
    }

    /// Order-preserving — callers index-align these against their own arrays.
    static func forOutput(_ urls: [URL]) throws -> [RenderedOutput] {
        try urls.map { try forOutput($0) }
    }

    /// Decoded, downsampled, orientation-corrected image for a rendering export
    /// (the PDF). Callers keep their own decode-budget guard: this is the
    /// render step, not the safety step.
    static func image(_ out: RenderedOutput, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(out.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}
