//
//  AutoToneStats.swift
//  Muse
//
//  Auto-tone's statistics, and the two scoped appliers.
//
//  Deliberately NOT `EditSession.stats`: that one is tapped from the RENDERED
//  image and gated on `statsVisible`, so it describes the current draft rather
//  than the original, and is absent entirely while the Histogram card is
//  closed. Auto must measure the ORIGINAL every time, or a second press
//  compounds its own output and the button stops being idempotent.
//
//  It also needs finer bins than the shipped histogram: `HistogramData.binCount`
//  is 64, so each bin is ~4% wide and a 0.1% black-point percentile cannot be
//  read off it. Three shipped consumers depend on that constant, so this
//  declares its own rather than changing it.
//
//  Pure arithmetic over an RGBA8 buffer, unit-tested on synthetic frames.
//  Platform-neutral by the `Editing/` rule: Foundation only.
//

import Foundation

nonisolated enum AutoToneStats {

    /// Finer than `HistogramData.binCount` on purpose — see the file note.
    static let binCount = 256

    /// Fraction of pixels allowed to sit outside the black/white points. The
    /// classic auto-levels shoulder: without it one hot pixel defines white.
    static let clipFraction = 0.001

    /// Where a correctly-exposed frame's mean luma should land. Measured on the
    /// DISPLAY-ENCODED buffer this is handed, not on linear light.
    static let targetMeanLuma = 0.46

    /// Inter-percentile spread of an image that already has normal contrast.
    /// Narrower than this opens up; wider pulls back.
    static let targetSpread = 0.62

    struct Result: Equatable {
        var exposureEV: Double = 0
        var contrast: Double = 0
        var blacks: Double = 0
        var whites: Double = 0
        var temperature: Double = 0
        var tint: Double = 0

        static let none = Result()
    }

    static func compute(rgba8: [UInt8], width: Int, height: Int) -> Result {
        let pixelCount = width * height
        // Reject a truncated buffer rather than reading past its end.
        guard pixelCount > 0, rgba8.count >= pixelCount * 4 else { return .none }

        var lumaHistogram = [Int](repeating: 0, count: binCount)
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, sumLuma = 0.0

        for i in stride(from: 0, to: pixelCount * 4, by: 4) {
            let r = Double(rgba8[i]) / 255
            let g = Double(rgba8[i + 1]) / 255
            let b = Double(rgba8[i + 2]) / 255
            sumR += r; sumG += g; sumB += b
            // Rec.709 luma on the display-encoded values, matching what the
            // histogram panel shows the user.
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            sumLuma += y
            let bin = min(binCount - 1, max(0, Int(y * Double(binCount - 1))))
            lumaHistogram[bin] += 1
        }

        let n = Double(pixelCount)
        var out = Result()

        // --- Exposure: mean luma toward the target, expressed in stops.
        // A pure-black frame has no ratio to take, so it stays at 0 rather
        // than diverging.
        let mean = sumLuma / n
        if mean > 0.0001 {
            out.exposureEV = clamp(log2(targetMeanLuma / mean), -5, 5)
        }

        // --- Black / white points from clipped percentiles.
        let lowBin = percentileBin(lumaHistogram, count: n, fraction: clipFraction)
        let highBin = percentileBin(lumaHistogram, count: n, fraction: 1 - clipFraction)
        let low = Double(lowBin) / Double(binCount - 1)
        let high = Double(highBin) / Double(binCount - 1)

        // Distance from the ideal 0 and 1 endpoints, in slider units. A frame
        // whose darkest pixel already sits at 0 needs no black move at all.
        out.blacks = clamp(-low * 2.0, -1, 1)
        out.whites = clamp((1 - high) * 2.0, -1, 1)

        // --- Contrast from the inter-percentile spread.
        let spread = max(0.0001, high - low)
        out.contrast = clamp((targetSpread - spread) * 1.2, -1, 1)

        // --- Grey-world white balance. The average scene is neutral, so the
        // correction is the INVERSE of the measured cast: a red-heavy frame
        // gets a NEGATIVE (cooler) temperature. A sign error here doubles the
        // cast instead of removing it, which is why the tests pin both
        // directions.
        let avgR = sumR / n, avgG = sumG / n, avgB = sumB / n
        let avgAll = (avgR + avgG + avgB) / 3
        if avgAll > 0.0001 {
            out.temperature = clamp(-((avgR - avgB) / avgAll) * 0.8, -1, 1)
            out.tint = clamp(-((avgG - (avgR + avgB) / 2) / avgAll) * 0.8, -1, 1)
        }

        return out
    }

    /// First bin at or past `fraction` of the cumulative population.
    private static func percentileBin(_ histogram: [Int], count: Double,
                                      fraction: Double) -> Int {
        let target = count * fraction
        var running = 0.0
        for (i, v) in histogram.enumerated() {
            running += Double(v)
            if running >= target { return i }
        }
        return histogram.count - 1
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        v.isFinite ? min(max(v, lo), hi) : 0
    }
}

/// Which sliders each Auto button may write.
///
/// Split by CARD, matching the per-card Reset scope exactly: per-card Reset
/// "undoes that group and nothing else, so fixing the colour doesn't cost you
/// the tone work", and a button in Light that silently moved a Color slider
/// would break that promise.
nonisolated enum AutoToneApply {
    static func light(_ r: AutoToneStats.Result, onto stack: inout EditStack) {
        stack.setTone {
            $0.exposureEV = r.exposureEV
            $0.contrast = r.contrast
            $0.blacks = r.blacks
            $0.whites = r.whites
        }
    }

    static func color(_ r: AutoToneStats.Result, onto stack: inout EditStack) {
        stack.setColor {
            $0.temperature = r.temperature
            $0.tint = r.tint
        }
    }
}
