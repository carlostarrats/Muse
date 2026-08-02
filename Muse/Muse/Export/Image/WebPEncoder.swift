//
//  WebPEncoder.swift
//  Muse
//
//  WebP is the one export format ImageIO can't write. Verified rather than
//  assumed: CGImageDestinationCopyTypeIdentifiers() lists 22 writable types on
//  macOS 26.5 and WebP is not among them — ImageIO READS it and won't write it.
//  So the encoder is ours, via libwebp.
//
//  libwebp is the app's FIRST bundled binary dependency. It clears the
//  no-third-party-network rule the hard way — it is a codec, with no socket
//  anywhere in it — and it links STATICALLY, so there's no embedded framework
//  to sign and no repeat of the stale-signed-appex trap.
//
//  It is here rather than AVIF (which ImageIO writes for free) on the owner's
//  call: WebP is the format people have actually heard of and the one that
//  opens in more non-browser software. Cheap was not a good enough reason.
//

import Foundation
import CoreGraphics
import libwebp

nonisolated enum WebPEncoder {
    /// Whether a WebP encoder is linked into this build. `ExportFormat.available`
    /// consults it, so the card can never offer an output that can't be made.
    static var isAvailable: Bool { true }

    /// libwebp's own ceiling: dimensions are 14-bit fields in the bitstream.
    /// A larger image is refused here rather than handed to the encoder, which
    /// would fail with nothing to say.
    static let maxDimension = 16383

    /// Encodes an sRGB image as WebP.
    ///
    /// The pixels are redrawn through a CGContext rather than read from the
    /// source's backing store: `CGImage` makes no promise about stride,
    /// component order or premultiplication, and libwebp needs tightly-packed
    /// RGBA. Copying is the only way to be sure, and at export time one pass
    /// per file is not the cost that matters.
    static func encode(_ image: CGImage, quality: Double, lossless: Bool = false) throws -> Data {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= maxDimension, h <= maxDimension else {
            throw ExportPipeline.RenderError.encodeFailed
        }
        let bytesPerRow = w * 4
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ExportPipeline.RenderError.encodeFailed
        }
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * h)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            // PREMULTIPLIED, because a bitmap context can't be anything else —
            // CGBitmapContext rejects straight alpha (`.last`) outright and
            // returns nil, which is a silent encode failure if you don't know
            // to expect it. `unpremultiply` below is what libwebp actually gets.
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw ExportPipeline.RenderError.encodeFailed }
        unpremultiply(&buffer)

        var output: UnsafeMutablePointer<UInt8>?
        let size = buffer.withUnsafeBufferPointer { src -> Int in
            // Lossless is a DIFFERENT entry point, not quality = 100. WebP's
            // lossy encoder at 100 still transforms the image; only this one
            // reproduces the pixels exactly, which is the whole reason to
            // choose WebP over JPEG for graphics rather than photographs.
            lossless
                ? WebPEncodeLosslessRGBA(src.baseAddress, Int32(w), Int32(h),
                                         Int32(bytesPerRow), &output)
                : WebPEncodeRGBA(src.baseAddress, Int32(w), Int32(h), Int32(bytesPerRow),
                                 Float(min(1, max(0, quality)) * 100), &output)
        }
        guard size > 0, let output else { throw ExportPipeline.RenderError.encodeFailed }
        defer { WebPFree(output) }
        return Data(bytes: output, count: size)
    }

    /// Premultiplied RGBA → straight RGBA, in place.
    ///
    /// Core Graphics can only hand back premultiplied data; libwebp wants
    /// straight. Feeding it premultiplied would darken every semi-transparent
    /// pixel toward black — invisible on the opaque photographs that are the
    /// common case, and obvious the first time someone exports a logo.
    ///
    /// Fully opaque is the overwhelmingly common case and is skipped whole.
    private static func unpremultiply(_ buffer: inout [UInt8]) {
        buffer.withUnsafeMutableBufferPointer { buf in
            var i = 0
            while i + 3 < buf.count {
                let a = buf[i + 3]
                if a != 255 {
                    if a == 0 {
                        buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0
                    } else {
                        let alpha = Int(a)
                        for c in 0..<3 {
                            buf[i + c] = UInt8(min(255, (Int(buf[i + c]) * 255 + alpha / 2) / alpha))
                        }
                    }
                }
                i += 4
            }
        }
    }
}
