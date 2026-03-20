import Foundation
import ImageIO
import CoreGraphics

struct ThumbnailGenerator {

    static let maxDimension: CGFloat = 400

    /// Generates a JPEG thumbnail from the image at `sourceURL` and writes it to `outputURL`.
    /// The thumbnail preserves aspect ratio with the longest side capped at 400 px.
    /// Returns `false` on any failure — the caller should treat this as non-fatal.
    static func generateThumbnail(from sourceURL: URL, outputURL: URL) async -> Bool {
        return await Task.detached(priority: .utility) {
            // Load source image
            guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
                return false
            }

            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                return false
            }

            let originalWidth = CGFloat(cgImage.width)
            let originalHeight = CGFloat(cgImage.height)

            guard originalWidth > 0, originalHeight > 0 else {
                return false
            }

            // Calculate scale so the longest side <= maxDimension
            let longestSide = max(originalWidth, originalHeight)
            let scale = longestSide > maxDimension ? maxDimension / longestSide : 1.0

            let targetWidth  = max(1, Int((originalWidth  * scale).rounded()))
            let targetHeight = max(1, Int((originalHeight * scale).rounded()))

            // Create a bitmap context at the target size
            let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

            guard let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }

            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

            guard let scaledImage = context.makeImage() else {
                return false
            }

            // Export as JPEG at 0.8 quality
            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                "public.jpeg" as CFString,
                1,
                nil
            ) else {
                return false
            }

            let properties: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: 0.8
            ]

            CGImageDestinationAddImage(destination, scaledImage, properties as CFDictionary)

            return CGImageDestinationFinalize(destination)
        }.value
    }
}
