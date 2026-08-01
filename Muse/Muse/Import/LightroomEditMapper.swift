//
//  LightroomEditMapper.swift
//  Muse
//
//  `LightroomEdits` → an `EditStack`, badged as approximated.
//
//  Every scale constant lives here, once. The RAW white-balance conversion
//  deliberately reads the RENDERER's own mired constant
//  (`MiredMapping.maxMiredOffset`) rather than restating it: the imported
//  number has to mean what the slider means, and two copies of that constant
//  would drift into meaning two different things.
//
//  What this does NOT do, on purpose: pin `rawParams.decoderVersion` (that is
//  the first USER edit's job — an import is not a decision to freeze a decoder
//  for all time), and never produce a neutral stack (nothing worth writing →
//  nil, so no row is created and the photo stays honestly unedited).
//

import Foundation
import CoreGraphics

nonisolated enum LightroomEditMapper {

    struct Context: Equatable, Sendable {
        var isRAW: Bool
        /// The camera's as-shot neutral, from `CIRAWFilter`. RAW WB is a
        /// DIFFERENCE from this; without it there is nothing to subtract, so WB
        /// is skipped rather than guessed.
        var asShotKelvin: Double?
        var asShotTint: Double?

        init(isRAW: Bool, asShotKelvin: Double? = nil, asShotTint: Double? = nil) {
            self.isRAW = isRAW
            self.asShotKelvin = asShotKelvin
            self.asShotTint = asShotTint
        }
    }

    static let lrContrastScale = 100.0
    static let lrVibranceScale = 100.0
    static let lrSaturationScale = 100.0
    static let lrIncrementalWBScale = 100.0
    /// Lightroom's tint runs −150…+150. There is no published mapping into
    /// `CIRAWFilter`'s tint units, so this is a directional normalization —
    /// squarely inside the "approximated, badged" envelope.
    static let lrTintScale = 150.0
    static let curveDomain = 255.0
    /// A curve within this of the identity diagonal is dropped.
    static let curveIdentityEpsilon = 0.5

    static func map(_ lr: LightroomEdits, context: Context) -> EditStack? {
        var stack = EditStack.fresh()

        // MARK: Geometry — the exact part.
        var geometry = GeometryParams.neutral
        if lr.hasCrop, let left = lr.cropLeft, let top = lr.cropTop,
           let right = lr.cropRight, let bottom = lr.cropBottom,
           right > left, bottom > top {
            geometry.crop = CropRect(x: clamp01(left), y: clamp01(top),
                                     w: clamp01(right - left), h: clamp01(bottom - top))
        }
        if let angle = lr.cropAngle, angle != 0 {
            // Lightroom stores the angle the crop rectangle was rotated BY;
            // straightening the image is the opposite rotation.
            geometry.straightenDegrees = min(max(-angle, -45), 45)
        }
        if let orientation = lr.orientation, let mapped = orientationTable[orientation] {
            geometry.quarterTurns = mapped.quarterTurns
            geometry.flipH = mapped.flipH
            geometry.flipV = mapped.flipV
        }
        if !geometry.isNeutral { stack.setGeometry { $0 = geometry.clamped() } }

        // MARK: Tone — exposure in real EV, contrast normalized.
        var tone = ToneParams.neutral
        if let exposure = lr.exposure2012 {
            tone.exposureEV = min(max(exposure, -5), 5)
        }
        if let contrast = lr.contrast2012 {
            tone.contrast = unit(contrast / lrContrastScale)
        }
        if !tone.isNeutral { stack.setTone { $0 = tone } }

        // MARK: Color — WB + the two directional saturation sliders.
        var color = ColorParams.neutral
        if context.isRAW {
            if let target = lr.temperatureKelvin, let asShot = context.asShotKelvin,
               target > 0, asShot > 0 {
                let miredDelta = (1_000_000.0 / target) - (1_000_000.0 / asShot)
                color.temperature = unit(miredDelta / MiredMapping.maxMiredOffset)
            }
            if let tint = lr.tint, let asShotTint = context.asShotTint {
                color.tint = unit((tint - asShotTint) / lrTintScale)
            }
        } else {
            if let t = lr.incrementalTemperature { color.temperature = unit(t / lrIncrementalWBScale) }
            if let t = lr.incrementalTint { color.tint = unit(t / lrIncrementalWBScale) }
        }
        if let vibrance = lr.vibrance { color.vibrance = unit(vibrance / lrVibranceScale) }
        if let saturation = lr.saturation { color.saturation = unit(saturation / lrSaturationScale) }
        if !color.isNeutral { stack.setColor { $0 = color } }

        // MARK: Curves — portable as curves, with the base-look caveat stated
        // in the report rather than compensated for here.
        var curve = CurveParams.neutral
        curve.rgb = normalizeCurve(lr.toneCurvePV2012)
        curve.red = normalizeCurve(lr.toneCurveRed)
        curve.green = normalizeCurve(lr.toneCurveGreen)
        curve.blue = normalizeCurve(lr.toneCurveBlue)
        if !curve.isNeutral { stack.setCurve { $0 = curve } }

        let normalized = stack.normalized()
        guard !normalized.isNeutral else { return nil }
        var out = normalized
        out.origin = .lightroom
        return out
    }

    // MARK: - Helpers

    /// EXIF orientation 1–8 → Muse geometry. Pure table; all eight covered.
    static let orientationTable: [Int: (quarterTurns: Int, flipH: Bool, flipV: Bool)] = [
        1: (0, false, false),
        2: (0, true, false),
        3: (2, false, false),
        4: (0, false, true),
        5: (3, true, false),
        6: (1, false, false),
        7: (1, true, false),
        8: (3, false, false),
    ]

    /// 0…255 Lightroom points → 0…1 Muse points; identity curves dropped;
    /// oversized curves keep BOTH endpoints and evenly subsample the interior
    /// (dropping the tail would change where the curve lands at white).
    static func normalizeCurve(_ points: [CGPoint]) -> [CurveParams.Point] {
        guard points.count >= 2 else { return [] }
        let sorted = points.sorted { $0.x < $1.x }
        let isIdentity = sorted.allSatisfy { abs($0.x - $0.y) <= curveIdentityEpsilon }
        if isIdentity { return [] }

        let subsampled = subsample(sorted, limit: CurveParams.maxPoints)
        return subsampled.map {
            CurveParams.Point(x: clamp01(Double($0.x) / curveDomain),
                              y: clamp01(Double($0.y) / curveDomain))
        }
    }

    private static func subsample(_ points: [CGPoint], limit: Int) -> [CGPoint] {
        guard points.count > limit, limit >= 2 else { return points }
        var out: [CGPoint] = [points[0]]
        let interior = limit - 2
        if interior > 0 {
            let span = points.count - 2
            for i in 0..<interior {
                let index = 1 + Int((Double(i) * Double(span - 1) / Double(max(interior - 1, 1))).rounded())
                let clamped = min(max(index, 1), points.count - 2)
                if out.last != points[clamped] { out.append(points[clamped]) }
            }
        }
        out.append(points[points.count - 1])
        return out
    }

    private static func unit(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, -1), 1)
    }

    private static func clamp01(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, 0), 1)
    }
}
