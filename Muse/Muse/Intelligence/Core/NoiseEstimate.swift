//
//  NoiseEstimate.swift
//  Muse
//
//  Robust noise sigma: MAD (×1.4826) of the 3×3 Laplacian response over the
//  FLATTEST half of 32×32 luminance tiles.
//
//  The flat-tile restriction is the whole algorithm. High-frequency content is
//  not noise — a checkerboard is busy and perfectly clean — so only regions
//  that should be smooth can testify about the sensor. Normalized to 1024 px
//  like `SharpnessScore`, so a 4× larger scan doesn't read as proportionally
//  noisier.
//

import CoreGraphics
import Accelerate

nonisolated enum NoiseEstimate {
    static let normalizedLongEdge = 1024
    private static let tileSize = 32
    private static let madToSigma = 1.4826

    static func sigma(_ cgImage: CGImage) -> Double? {
        guard cgImage.width > 64, cgImage.height > 64 else { return nil }

        let longEdge = max(cgImage.width, cgImage.height)
        let scale = longEdge > normalizedLongEdge
            ? Double(normalizedLongEdge) / Double(longEdge) : 1.0
        let width = max(Int(Double(cgImage.width) * scale), 1)
        let height = max(Int(Double(cgImage.height) * scale), 1)
        guard width >= tileSize, height >= tileSize,
              var luma = grayscalePixels(cgImage, width: width, height: height)
        else { return nil }

        var laplacian = [Float](repeating: 0, count: width * height)
        let kernel: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        vDSP_f3x3(&luma, vDSP_Length(height), vDSP_Length(width), kernel, &laplacian)

        let tilesX = width / tileSize
        let tilesY = height / tileSize
        guard tilesX > 0, tilesY > 0 else { return nil }

        var tileResponses: [[Float]] = []
        var tileVariances: [(index: Int, variance: Float)] = []
        tileResponses.reserveCapacity(tilesX * tilesY)
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                var responses = [Float]()
                responses.reserveCapacity(tileSize * tileSize)
                for y in (ty * tileSize)..<((ty + 1) * tileSize) {
                    let row = y * width
                    for x in (tx * tileSize)..<((tx + 1) * tileSize) {
                        responses.append(laplacian[row + x])
                    }
                }
                var mean: Float = 0
                vDSP_meanv(responses, 1, &mean, vDSP_Length(responses.count))
                var variance: Float = 0
                for r in responses { variance += (r - mean) * (r - mean) }
                variance /= Float(responses.count)
                tileVariances.append((tileResponses.count, variance))
                tileResponses.append(responses)
            }
        }

        let flattestCount = max(tileVariances.count / 2, 1)
        let flattest = tileVariances.sorted { $0.variance < $1.variance }.prefix(flattestCount)
        var pooled: [Float] = []
        for entry in flattest { pooled.append(contentsOf: tileResponses[entry.index]) }
        guard !pooled.isEmpty else { return nil }

        vDSP_vsort(&pooled, vDSP_Length(pooled.count), 1)
        let median = pooled[pooled.count / 2]
        var deviations = pooled.map { abs($0 - median) }
        vDSP_vsort(&deviations, vDSP_Length(deviations.count), 1)
        return Double(deviations[deviations.count / 2]) * madToSigma
    }

    private static func grayscalePixels(_ cgImage: CGImage, width: Int, height: Int) -> [Float]? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: colorSpace, bitmapInfo: 0)
            else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return buffer.map { Float($0) }
    }
}
