//
//  PhotoFeedback.swift
//  Muse
//
//  "Why it looks this way" — deterministic, rule-based, NEVER an LLM.
//
//  Every input is a PRECOMPUTED column (`photo_meta` + `photo_traits`), so
//  showing this card can't trigger a decode or a query-time analysis. The rule
//  table is Swift-declared rather than a data file because string extraction
//  can't see a data file, and these sentences must localize like everything
//  else.
//
//  Two suppressions carry the design: flash suppresses the motion-blur note
//  (the flash IS the exposure), and motion blur suppresses the soft-focus note
//  (cause beats symptom — one blur, one explanation). An empty result renders
//  NO card: silence is the good outcome, not a fallback state.
//

import Foundation

nonisolated enum PhotoFeedback {

    struct Inputs: Equatable, Sendable {
        var iso: Int?
        var exposureSeconds: Double?
        var fNumber: Double?
        var focalLength35: Double?
        var flashFired: Bool?
        var sharpness: Double?
        var faceCount: Int?
        var clipHighR: Double?
        var clipHighG: Double?
        var clipHighB: Double?
        var clipLow: Double?
        var noiseSigma: Double?
    }

    enum Note: Equatable, Sendable {
        case clippedHighlights(percent: Double, channel: RGBChannel?)
        case crushedShadows(percent: Double)
        case motionBlurRisk(shutterSeconds: Double)
        case highISONoise(iso: Int, wellControlled: Bool)
        case softFocus
        case thinFocusPlane(fNumber: Double, hasFaces: Bool)

        var displayText: String {
            switch self {
            case .clippedHighlights(let percent, let channel):
                let pct = String(format: "%.1f", percent * 100)
                if let channel {
                    return String(localized: "\(pct)% of pixels are clipped in the \(channel.clippingName) channel — those areas have lost detail.")
                }
                return String(localized: "\(pct)% of pixels are clipped — those areas have lost detail.")
            case .crushedShadows(let percent):
                let pct = String(format: "%.0f", percent * 100)
                return String(localized: "Deep shadows cover \(pct)% of the frame — some shadow detail is gone.")
            case .motionBlurRisk(let shutterSeconds):
                let fraction = shutterSeconds > 0 ? Int((1.0 / shutterSeconds).rounded()) : 0
                return String(localized: "Handheld at 1/\(fraction) s — motion blur is likely.")
            case .highISONoise(let iso, let wellControlled):
                if wellControlled {
                    return String(localized: "Shadows are noisy because ISO \(iso), though noise is well controlled here.")
                }
                return String(localized: "Shadows are noisy because ISO \(iso).")
            case .softFocus:
                return String(localized: "This photo is soft — focus may have missed.")
            case .thinFocusPlane(let fNumber, let hasFaces):
                let f = String(format: "%.1f", fNumber)
                if hasFaces {
                    return String(localized: "Shot at f/\(f) — a thin focus plane; check the eyes.")
                }
                return String(localized: "Shot at f/\(f) — a thin focus plane.")
            }
        }
    }

    /// Three is what a card can say without becoming a wall of complaints.
    static let maxNotes = 3

    // Named thresholds, one declaration site each.
    private static let clipNoteFloor = 0.002
    private static let shadowNoteFloor = 0.02
    private static let channelDominanceRatio = 3.0
    /// The reciprocal rule needs a focal length; a phone that reports none is
    /// close enough to a normal lens for this purpose.
    private static let handheldFallbackFocal = 50.0
    private static let noiseISOFloor = 3200
    /// Below this measured sigma, a high ISO is worth mentioning but not worth
    /// worrying about — modern sensors earn the qualifier. Owner-tunable.
    private static let noiseSigmaQuiet = 2.0
    private static let thinApertureCeiling = 2.0

    /// Fixed severity order: clipping → shadows → motion → noise → soft → thin.
    /// The order is the ranking; the cap is applied at the end, so the three
    /// most serious things always survive.
    static func notes(for inputs: Inputs) -> [Note] {
        var notes: [Note] = []
        var motionBlurFired = false

        let highs = [inputs.clipHighR, inputs.clipHighG, inputs.clipHighB].compactMap { $0 }
        if let maxHigh = highs.max(), maxHigh >= clipNoteFloor {
            let secondHighest = highs.filter { $0 != maxHigh }.max() ?? 0
            let dominant = secondHighest > 0 && maxHigh >= secondHighest * channelDominanceRatio
            notes.append(.clippedHighlights(percent: maxHigh,
                                            channel: dominant ? dominantChannel(inputs) : nil))
        }

        if let clipLow = inputs.clipLow, clipLow >= shadowNoteFloor {
            notes.append(.crushedShadows(percent: clipLow))
        }

        if let exposureSeconds = inputs.exposureSeconds {
            let focal = inputs.focalLength35 ?? handheldFallbackFocal
            let risky = exposureSeconds >= 1.0 / max(focal, 1)
            if risky, inputs.flashFired != true {
                notes.append(.motionBlurRisk(shutterSeconds: exposureSeconds))
                motionBlurFired = true
            }
        }

        if let iso = inputs.iso, iso >= noiseISOFloor {
            let wellControlled = (inputs.noiseSigma ?? .greatestFiniteMagnitude) < noiseSigmaQuiet
            notes.append(.highISONoise(iso: iso, wellControlled: wellControlled))
        }

        if let sharpness = inputs.sharpness, sharpness <= SharpnessScore.softCeiling,
           !motionBlurFired {
            notes.append(.softFocus)
        }

        if let fNumber = inputs.fNumber, fNumber <= thinApertureCeiling {
            notes.append(.thinFocusPlane(fNumber: fNumber, hasFaces: (inputs.faceCount ?? 0) >= 1))
        }

        return Array(notes.prefix(maxNotes))
    }

    private static func dominantChannel(_ inputs: Inputs) -> RGBChannel {
        let r = inputs.clipHighR ?? 0, g = inputs.clipHighG ?? 0, b = inputs.clipHighB ?? 0
        if r >= g && r >= b { return .red }
        if g >= r && g >= b { return .green }
        return .blue
    }
}
