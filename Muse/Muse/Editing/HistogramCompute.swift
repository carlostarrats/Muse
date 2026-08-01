//
//  HistogramCompute.swift
//  Muse
//
//  Pure statistics over raw pixel buffers — no Core Image, unit-tested on
//  synthetic gradients. ONE pass feeds three consumers: the teaching histogram
//  (`ScopesPanel`), the curve panel's histogram-behind, and the tone-zone
//  strip's mass bars. See `EditSession.stats`.
//
//  The thresholds are always passed IN: the live editor tap passes the user's
//  zebra prefs (so the number on screen agrees with the stripes), and the
//  capture-stats pass passes `ClippingStats.stored*` (so a DB row doesn't
//  change meaning when a slider moves).
//

import Foundation

nonisolated struct HistogramData: Equatable, Sendable {
    static let binCount = 64
    var r: [Float]
    var g: [Float]
    var b: [Float]
    var luma: [Float]

    static let empty = HistogramData(r: .init(repeating: 0, count: binCount),
                                     g: .init(repeating: 0, count: binCount),
                                     b: .init(repeating: 0, count: binCount),
                                     luma: .init(repeating: 0, count: binCount))
}

nonisolated enum RGBChannel: Equatable, Sendable {
    case red, green, blue
}

/// Coarse vertical position of a clip-mass centroid, bucketed into thirds of
/// the frame. This is how the clipping copy gets a spatial hint ("mostly near
/// the top") from statistics ALONE — never scene semantics.
nonisolated enum FrameRegion: Equatable, Sendable {
    case top, middle, bottom
}

nonisolated struct ClippingStats: Equatable, Sendable {
    /// Fixed thresholds for STORED capture stats (`photo_traits`) — pref-
    /// independent, one declaration site. The EDITOR's live stats and zebras
    /// read `AppSettings.editorZebraHigh/Low` instead, never these.
    static let storedHighThreshold: Double = 254.0 / 255.0
    static let storedLowThreshold: Double = 2.0 / 255.0

    var highR: Double
    var highG: Double
    var highB: Double
    var low: Double
    /// 0 (top) … 1 (bottom) row centroid of the clipped mass; nil when nothing
    /// clipped — a centroid of "no pixels" is not zero, it's absent.
    var highMassCenterY: Double?
    var lowMassCenterY: Double?

    static let none = ClippingStats(highR: 0, highG: 0, highB: 0, low: 0,
                                    highMassCenterY: nil, lowMassCenterY: nil)
}

nonisolated struct CurveHistogram: Equatable, Sendable {
    /// 64 luminance bins, drawn as a silent backdrop behind the curve.
    let bins: [Float]
}

/// Everything one completed render produces for the readouts. Written to the
/// session as ONE value so histogram/clipping/zone data can never be a frame
/// out of step with each other.
nonisolated struct EditStats: Equatable, Sendable {
    var histogram: HistogramData
    var clipping: ClippingStats
    var zoneMass: [Double]
    var curveHistogram: CurveHistogram
}

/// The tone-zone stage's smoothed-EV buffer at stats-tap resolution, shared by
/// the hover readout and the overlay's hit test. NOT published on the session:
/// a per-render buffer publish would re-render every observing panel for
/// nothing, and consumers only need it on hover.
nonisolated struct ZoneEVMap: Sendable {
    let width: Int
    let height: Int
    let values: [Float]
}

nonisolated enum HistogramCompute {

    /// One pass over an RGBA8 buffer producing both the 64-bin histogram and
    /// the clipping fractions/centroids at the caller's thresholds.
    static func compute(rgba8: [UInt8], width: Int, height: Int,
                        highThreshold: Double, lowThreshold: Double)
        -> (histogram: HistogramData, clipping: ClippingStats) {
        guard width > 0, height > 0, rgba8.count >= width * height * 4 else {
            return (.empty, .none)
        }
        let bins = HistogramData.binCount
        var rBins = [Int](repeating: 0, count: bins)
        var gBins = [Int](repeating: 0, count: bins)
        var bBins = [Int](repeating: 0, count: bins)
        var lumaBins = [Int](repeating: 0, count: bins)

        var highRCount = 0, highGCount = 0, highBCount = 0, lowCount = 0
        var highPixelCount = 0
        var highYSum: Double = 0, lowYSum: Double = 0
        let pixelCount = width * height

        let highT = highThreshold * 255.0
        let lowT = lowThreshold * 255.0

        for y in 0..<height {
            let rowBase = y * width * 4
            for x in 0..<width {
                let i = rowBase + x * 4
                let r = Double(rgba8[i]), g = Double(rgba8[i + 1]), b = Double(rgba8[i + 2])
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b

                rBins[binIndex(for: r, bins: bins)] += 1
                gBins[binIndex(for: g, bins: bins)] += 1
                bBins[binIndex(for: b, bins: bins)] += 1
                lumaBins[binIndex(for: luma, bins: bins)] += 1

                var clippedHigh = false
                if r >= highT { highRCount += 1; clippedHigh = true }
                if g >= highT { highGCount += 1; clippedHigh = true }
                if b >= highT { highBCount += 1; clippedHigh = true }
                if clippedHigh { highPixelCount += 1; highYSum += Double(y) }
                if luma <= lowT { lowCount += 1; lowYSum += Double(y) }
            }
        }

        // Normalized so the tallest bin ACROSS channels is 1 — per-channel
        // normalization would hide a channel that's genuinely quieter.
        let maxBin = Double([rBins, gBins, bBins, lumaBins].flatMap { $0 }.max() ?? 1)
        let normalize: ([Int]) -> [Float] = { counts in
            counts.map { maxBin > 0 ? Float(Double($0) / maxBin) : 0 }
        }

        let histogram = HistogramData(r: normalize(rBins), g: normalize(gBins),
                                      b: normalize(bBins), luma: normalize(lumaBins))
        let denominator = Double(max(height - 1, 1))
        let clipping = ClippingStats(
            highR: Double(highRCount) / Double(pixelCount),
            highG: Double(highGCount) / Double(pixelCount),
            highB: Double(highBCount) / Double(pixelCount),
            low: Double(lowCount) / Double(pixelCount),
            highMassCenterY: highPixelCount > 0
                ? (highYSum / Double(highPixelCount)) / denominator : nil,
            lowMassCenterY: lowCount > 0 ? (lowYSum / Double(lowCount)) / denominator : nil)

        return (histogram, clipping)
    }

    private static func binIndex(for value: Double, bins: Int) -> Int {
        let clamped = min(max(value / 255.0, 0), 1)
        return min(Int(clamped * Double(bins)), bins - 1)
    }

    static func frameRegion(forCenterY y: Double?) -> FrameRegion? {
        guard let y else { return nil }
        if y <= 1.0 / 3.0 { return .top }
        if y >= 2.0 / 3.0 { return .bottom }
        return .middle
    }

    /// Fractional pixel mass per tone zone, from the smoothed-EV buffer the
    /// render stage already computed. Sums to ~1 (the weights are a partition
    /// of unity; float rounding can land fractionally under).
    static func zoneMass(evMap: [Float], width: Int, height: Int) -> [Double] {
        var mass = [Double](repeating: 0, count: ToneZoneParams.zoneCount)
        guard width > 0, height > 0, evMap.count >= width * height else { return mass }
        let total = Double(width * height)
        for index in 0..<(width * height) {
            let weights = ToneZoneMath.weights(forEV: Double(evMap[index]))
            for i in 0..<ToneZoneParams.zoneCount {
                mass[i] += weights[i] / total
            }
        }
        return mass
    }

    /// Fills Spec 04's `CurveEditorView(histogram:)` seam — the curve's silent
    /// backdrop is exactly the luma channel of the same shared histogram.
    static func curveHistogram(from histogram: HistogramData) -> CurveHistogram {
        CurveHistogram(bins: histogram.luma)
    }
}
