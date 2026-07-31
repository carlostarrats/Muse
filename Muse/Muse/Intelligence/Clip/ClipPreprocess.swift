//
//  ClipPreprocess.swift
//  Muse
//
//  Aspect-FILL scale + center crop to `imageInputSide`, sRGB. CLIP's input
//  normalization (mean/std) is baked into the Core ML image encoder's input
//  layer by the conversion script — this file supplies a plain RGB pixel
//  buffer and never applies mean/std itself.
//

import CoreGraphics
import CoreVideo

nonisolated enum ClipPreprocess {
    /// The center-square crop rect, in ORIGINAL image pixel coordinates, that
    /// an aspect-fill-then-crop-to-`side` would take.
    static func cropRect(imageSize: CGSize, side: Int) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let shortEdge = min(imageSize.width, imageSize.height)
        let x = (imageSize.width - shortEdge) / 2
        let y = (imageSize.height - shortEdge) / 2
        return CGRect(x: x, y: y, width: shortEdge, height: shortEdge)
    }

    static func pixelBuffer(from cgImage: CGImage, side: Int) -> CVPixelBuffer? {
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let crop = cropRect(imageSize: imageSize, side: side)
        guard crop != .zero, let cropped = cgImage.cropping(to: crop) else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                       kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                                          kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }
}
