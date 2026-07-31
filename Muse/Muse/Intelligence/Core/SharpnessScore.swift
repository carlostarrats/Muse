//
//  SharpnessScore.swift
//  Muse
//
//  log10(variance of 3x3 Laplacian) over luminance, downsampled to a FIXED
//  long edge before scoring — variance-of-Laplacian scales with pixel
//  pitch, so an unnormalized score would rank a 12 MP and 48 MP shot of the
//  same scene differently. Comparable only WITHIN one machine/Vision
//  revision/session (relative ranking, never an absolute cross-library
//  scale) — see SharpnessRank.
//

import Accelerate
import CoreGraphics

nonisolated enum SharpnessScore {
    static let normalizedLongEdge = 1024

    /// Owner-validated (never live-validated against real photos yet).
    static let softCeiling: Double = 2.5
    static let sharpFloor: Double = 3.5

    enum Bucket: Equatable { case soft, moderate, sharp }

    static func bucket(_ score: Double) -> Bucket {
        if score <= softCeiling { return .soft }
        if score >= sharpFloor { return .sharp }
        return .moderate
    }

    /// nil for degenerate (<= 8px) input or a failed vImage conversion.
    static func score(_ cgImage: CGImage) -> Double? {
        guard cgImage.width > 8, cgImage.height > 8 else { return nil }

        let longEdge = max(cgImage.width, cgImage.height)
        let scale = longEdge > normalizedLongEdge
            ? Double(normalizedLongEdge) / Double(longEdge) : 1.0
        let width = max(1, Int(Double(cgImage.width) * scale))
        let height = max(1, Int(Double(cgImage.height) * scale))
        guard width > 8, height > 8 else { return nil }

        let grayColorSpace = CGColorSpaceCreateDeviceGray()
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 8,
            colorSpace: Unmanaged.passUnretained(grayColorSpace),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            version: 0, decode: nil, renderingIntent: .defaultIntent)

        var sourceBuffer = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&sourceBuffer, &format, nil, cgImage,
                                            vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }
        defer { free(sourceBuffer.data) }

        var gray = vImage_Buffer()
        guard vImageBuffer_Init(&gray, vImagePixelCount(height), vImagePixelCount(width),
                                 8, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }
        defer { free(gray.data) }
        guard vImageScale_Planar8(&sourceBuffer, &gray, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }

        var laplacian = vImage_Buffer()
        guard vImageBuffer_Init(&laplacian, vImagePixelCount(height), vImagePixelCount(width),
                                 8, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }
        defer { free(laplacian.data) }

        // Bias 128 keeps the signed Laplacian representable in the UInt8 output;
        // it's a constant offset, so it cancels out of the variance.
        let kernel: [Int16] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        let err = vImageConvolve_Planar8(&gray, &laplacian, nil, 0, 0, kernel, 3, 3,
                                          1, 128, vImage_Flags(kvImageEdgeExtend))
        guard err == kvImageNoError else { return nil }

        let rowBytes = laplacian.rowBytes
        let count = width * height
        var floatBuf = [Float](repeating: 0, count: count)
        guard let base = laplacian.data?.bindMemory(to: UInt8.self, capacity: rowBytes * height) else {
            return nil
        }
        floatBuf.withUnsafeMutableBufferPointer { out in
            guard let outBase = out.baseAddress else { return }
            for row in 0..<height {
                vDSP_vfltu8(base.advanced(by: row * rowBytes), 1,
                            outBase.advanced(by: row * width), 1, vDSP_Length(width))
            }
        }

        var mean: Float = 0
        vDSP_meanv(floatBuf, 1, &mean, vDSP_Length(count))
        var variance: Float = 0
        var negMean = -mean
        var centered = [Float](repeating: 0, count: count)
        vDSP_vsadd(floatBuf, 1, &negMean, &centered, 1, vDSP_Length(count))
        vDSP_measqv(centered, 1, &variance, vDSP_Length(count))

        guard variance > 0 else { return -Double.greatestFiniteMagnitude }
        return log10(Double(variance))
    }
}
