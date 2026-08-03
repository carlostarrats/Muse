//
//  ToneZoneMath.swift
//  Muse
//
//  Pure math for the tone-zone control — a raised-cosine partition of unity
//  over EV. The Metal kernel (`toneZoneGain`) mirrors this formula rather than
//  sharing code (Metal can't call Swift); the two are pinned together through
//  the render consistency/neutrality goldens, not by inspection.
//
//  The partition-of-unity property is what makes the control safe: at every
//  EV the nine weights sum to exactly 1, so all-equal gains are a plain
//  exposure shift and all-zero gains are an exact identity.
//

import Foundation

nonisolated enum ToneZoneMath {
    static let zoneCount = ToneZoneParams.zoneCount     // 9
    /// Zone 0's centre — the deepest shadows we address.
    static let evFloor: Double = -8
    /// Zone 8's centre — diffuse white.
    static let evCeiling: Double = 0
    /// A gain of ±1 maps to ±2 EV. Owner-tunable.
    static let maxZoneEV: Double = 2.0

    static let stepEV = (evCeiling - evFloor) / Double(zoneCount - 1)

    static func zoneCenterEV(_ index: Int) -> Double {
        evFloor + Double(index) * stepEV
    }

    /// Raised-cosine weights over EV, normalized to sum to 1. Each raw weight
    /// peaks at 1 at its own zone's centre and reaches 0 at the neighbouring
    /// centres; the end zones are clamped, so an EV past either end resolves
    /// to the same weights as the end itself.
    static func weights(forEV ev: Double) -> [Double] {
        let clampedEV = min(max(ev, evFloor), evCeiling)
        var raw = [Double](repeating: 0, count: zoneCount)
        for i in 0..<zoneCount {
            let distance = abs(clampedEV - zoneCenterEV(i)) / stepEV
            if distance < 1 {
                raw[i] = 0.5 * (1 + cos(.pi * distance))
            }
        }
        let sum = raw.reduce(0, +)
        guard sum > 0 else {
            // Unreachable for a finite EV in range (every point is within one
            // step of a centre), but a NaN input would land here rather than
            // dividing by zero.
            var oneHot = [Double](repeating: 0, count: zoneCount)
            oneHot[0] = 1
            return oneHot
        }
        return raw.map { $0 / sum }
    }

    /// The single zone whose weight is highest at this EV — the strip's hover
    /// mapping and the overlay's dominant-zone test.
    static func zoneIndex(forEV ev: Double) -> Int {
        let w = weights(forEV: ev)
        var bestIndex = 0
        var bestWeight = w[0]
        for i in 1..<w.count where w[i] > bestWeight {
            bestWeight = w[i]
            bestIndex = i
        }
        return bestIndex
    }

    /// Where a drag lands a zone's gain: the value the press STARTED from plus
    /// the pointer's total travel, one gain-point per screen point so the black
    /// line stays under the cursor. `translationPoints` is SwiftUI's, positive
    /// downward, and down means darker.
    ///
    /// The anchor is a parameter on purpose. The strip used to read the CURRENT
    /// gain and add the gesture's cumulative translation to it, which re-applied
    /// every earlier point of the same drag — the gain grew with the square of
    /// the distance and the line shot off ahead of the pointer within a few
    /// pixels. A function that cannot see the current gain cannot regress that
    /// way.
    static func draggedGain(anchor: Double,
                            translationPoints: Double,
                            cellHeight: Double) -> Double {
        // The gain range (−1…+1) is drawn across the cell's full height.
        let perPoint = 2.0 / max(cellHeight, 1)
        return min(max(anchor - translationPoints * perPoint, -1), 1)
    }

    /// Σ(weight_i · gain_i · maxZoneEV) — the exposure offset a pixel at this
    /// EV receives. Exactly 0 at all-zero gains, which is the neutrality
    /// golden's whole point.
    static func gainEV(forEV ev: Double, gains: [Double]) -> Double {
        let w = weights(forEV: ev)
        let g = gains.count == zoneCount ? gains : ToneZoneParams(gains: gains).clamped().gains
        var total = 0.0
        for i in 0..<zoneCount { total += w[i] * g[i] * maxZoneEV }
        return total
    }
}
