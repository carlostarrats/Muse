//
//  RawSource.swift
//  Muse
//
//  The RAW half of the hybrid pipeline. Two rules do all the work here:
//
//  1. **Neutralize Apple's default look.** `CIRAWFilter` ships a pleasing
//     baked-in rendering (baseline exposure, shadow bias, boost, local tone
//     map). Leaving it on means the user's Exposure slider fights a curve they
//     can't see, and the same stack renders differently on a RAW and a JPEG of
//     the same scene. Every one of those is zeroed (WWDC21 §10160).
//  2. **White balance happens ONLY at demosaic.** `CITemperatureAndTint` on a
//     RAW source's OUTPUT is white-balancing an already-white-balanced image;
//     the correct knob is the filter's own `neutralTemperature`/`neutralTint`,
//     offset in mired from the as-shot neutral.
//
//  Every property set goes through `setIfSupported` — the supported set varies
//  by camera model and SDK, and setting an unsupported key throws.
//

import CoreImage
import Foundation

/// Temperature slider → mired offset.
///
/// Mired (10⁶/K) rather than Kelvin because Kelvin is perceptually non-linear:
/// 3000K→4000K is a large visible shift and 9000K→10000K is barely anything,
/// so a Kelvin-linear slider is warm/cool asymmetric — the exact bug this
/// mapping exists to avoid (Surface Camera's `ToneFilterStage` lesson).
/// Equal mired steps read as equal perceptual steps.
nonisolated enum MiredMapping {
    static let d65Mired = 1_000_000.0 / 6500.0        // ≈154
    /// Below ~25 mired (40000K) the maths stops being meaningful and the
    /// result is an unusable blue; this is the cool end of the range.
    static let miredFloor = 25.0
    /// Slider ±1. The range is DERIVED from the floor rather than picked, so
    /// warm and cool are symmetric BY CONSTRUCTION: pick a warm target Kelvin
    /// independently and the cool side runs past the floor, gets clamped, and
    /// the slider is quietly asymmetric again — the exact bug this type exists
    /// to prevent.
    static let maxMiredOffset = d65Mired - miredFloor  // ≈129
    /// What slider +1 works out to, for reference/diagnostics (≈3540 K).
    static var warmTargetKelvin: Double { 1_000_000.0 / (d65Mired + maxMiredOffset) }

    static func miredOffset(forSliderValue value: Double) -> Double {
        let clamped = min(max(value, -1), 1)
        return clamped * maxMiredOffset
    }

    /// Apply a mired offset to a concrete Kelvin temperature (the as-shot
    /// neutral, for RAW).
    static func kelvin(from baseKelvin: Double, miredOffset: Double) -> Double {
        let mired = max(1_000_000.0 / max(baseKelvin, 1) + miredOffset, miredFloor)
        return 1_000_000.0 / mired
    }
}

nonisolated enum RawSource {
    /// Tint slider (−1…+1) → `CIRAWFilter`'s neutral-tint units.
    static let tintScale = 50.0

    /// `maxPixel == 0` means full resolution (the export path). Anything else
    /// is a PROXY, and the decoder is told so via `scaleFactor` BEFORE
    /// `outputImage` is read.
    ///
    /// This is load-bearing for the "edit preview renders at screen
    /// resolution, never full-res" budget (foundation §9): without it every
    /// slider tick demosaiced the full 24–60 MP frame and then threw most of
    /// it away in a CIImage scale transform downstream. Scaling at demosaic is
    /// what Apple's own RAW-preview guidance prescribes.
    static func decode(url: URL, params: RawParams?, color: ColorParams,
                       presence: PresenceParams, maxPixel: Int = 0) -> LinearImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }

        // 0. Proxy scale, first — it changes what everything below decodes.
        if maxPixel > 0 {
            let native = filter.nativeSize
            let longEdge = max(native.width, native.height)
            if longEdge > 0, CGFloat(maxPixel) < longEdge {
                filter.scaleFactor = Float(CGFloat(maxPixel) / longEdge)
            }
        }

        // 1. Neutralize the default look, so the sliders are the only thing
        //    shaping the image and RAW/JPEG agree on what a stack means.
        filter.baselineExposure = 0
        filter.shadowBias = 0
        filter.boostAmount = 0
        filter.localToneMapAmount = 0
        filter.isGamutMappingEnabled = false

        // 2. White balance, at demosaic only.
        let miredOffset = MiredMapping.miredOffset(forSliderValue: color.temperature)
        if miredOffset != 0 {
            filter.neutralTemperature = Float(
                MiredMapping.kelvin(from: Double(filter.neutralTemperature),
                                    miredOffset: miredOffset))
        }
        if color.tint != 0 {
            filter.neutralTint += Float(color.tint * tintScale)
        }

        // 3. The same NR/sharpen sliders the encoded path uses, routed to the
        //    decoder — which is where they belong for RAW.
        filter.luminanceNoiseReductionAmount = Float(presence.noiseReduction)
        filter.sharpnessAmount = Float(presence.sharpen)
        filter.isLensCorrectionEnabled = params?.lensCorrection ?? true

        guard let output = filter.outputImage else { return nil }
        // CIRAWFilter's output is ALREADY linear working space — running it
        // through EncodedImage would double-transform it.
        return LinearImage.alreadyDecodedFromFile(output)
    }

    /// The decoder version to pin at first edit, so a later OS can't silently
    /// re-render the same stack differently.
    static func currentDecoderVersion(for url: URL) -> String? {
        CIRAWFilter(imageURL: url)?.decoderVersion.rawValue
    }
}
