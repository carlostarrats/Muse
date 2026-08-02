//
//  WebPEncoder.swift
//  Muse
//
//  WebP is the one export format ImageIO can't write. Verified rather than
//  assumed: CGImageDestinationCopyTypeIdentifiers() lists 22 writable types on
//  macOS 26.5 and WebP is not among them — ImageIO READS it and won't write it.
//  The encoder is therefore ours, via libwebp.
//
//  Until that dependency lands this reports unavailable, and
//  ExportFormat.available simply doesn't offer WebP — every other format works.
//  That is deliberate sequencing, not an oversight: the feature ships complete
//  without its one third-party binary dependency.
//

import Foundation
import CoreGraphics

nonisolated enum WebPEncoder {
    /// Whether a WebP encoder is linked into this build. `ExportFormat`
    /// consults it, so the card can never offer an output that can't be made.
    static var isAvailable: Bool { false }

    static func encode(_ image: CGImage, quality: Double) throws -> Data {
        throw ExportPipeline.RenderError.encodeFailed
    }
}
