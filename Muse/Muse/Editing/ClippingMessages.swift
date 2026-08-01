//
//  ClippingMessages.swift
//  Muse
//
//  Plain-English clipping copy for the Scopes panel. Deterministic and
//  stats-only: the spatial flavour ("mostly near the top") comes from the
//  clip-mass row centroid, never from scene understanding — a histogram
//  cannot know it's looking at a sky, and pretending otherwise is how a
//  teaching feature starts lying.
//
//  These read the LIVE editor thresholds (the same values the zebra kernel
//  uses), so the percentage always describes what's striped on screen.
//

import Foundation

nonisolated enum ClippingMessage: Equatable {
    case highlightsClipping(percent: Double, channel: RGBChannel?, region: FrameRegion?)
    case shadowsCrushed(percent: Double, region: FrameRegion?)

    var displayText: String {
        switch self {
        case .highlightsClipping(let percent, let channel, let region):
            let pct = String(format: "%.1f", percent * 100)
            switch (channel, region) {
            case (.some(let ch), .some(let r)):
                return String(localized: "\(pct)% of pixels are clipping in the \(ch.clippingName) channel, mostly \(r.clippingName).")
            case (.some(let ch), .none):
                return String(localized: "\(pct)% of pixels are clipping in the \(ch.clippingName) channel.")
            case (.none, .some(let r)):
                return String(localized: "\(pct)% of pixels are clipped, mostly \(r.clippingName).")
            case (.none, .none):
                return String(localized: "\(pct)% of pixels are clipped — those areas have lost detail.")
            }
        case .shadowsCrushed(let percent, let region):
            let pct = String(format: "%.1f", percent * 100)
            if let region {
                return String(localized: "Deep shadows cover \(pct)% of the frame, mostly \(region.clippingName) — some shadow detail is gone.")
            }
            return String(localized: "Deep shadows cover \(pct)% of the frame — some shadow detail is gone.")
        }
    }
}

nonisolated enum ClippingMessages {
    /// Below 0.1% of the frame, stay silent — a handful of specular pixels is
    /// not a problem, and saying so every time trains the user to ignore this.
    static let messageFloor = 0.001
    /// One channel at ≥ 3× the others is worth naming; anything closer reads
    /// as ordinary highlight clipping.
    static let channelDominanceRatio = 3.0

    static func compose(_ c: ClippingStats) -> [ClippingMessage] {
        var messages: [ClippingMessage] = []

        let maxHigh = max(c.highR, max(c.highG, c.highB))
        if maxHigh >= messageFloor {
            let others = [c.highR, c.highG, c.highB].filter { $0 != maxHigh }
            let secondHighest = others.max() ?? 0
            let dominant = secondHighest > 0 && maxHigh >= secondHighest * channelDominanceRatio
            let channel: RGBChannel? = dominant ? dominantChannel(c) : nil
            messages.append(.highlightsClipping(
                percent: maxHigh, channel: channel,
                region: HistogramCompute.frameRegion(forCenterY: c.highMassCenterY)))
        }

        if c.low >= messageFloor {
            messages.append(.shadowsCrushed(
                percent: c.low,
                region: HistogramCompute.frameRegion(forCenterY: c.lowMassCenterY)))
        }

        return messages
    }

    private static func dominantChannel(_ c: ClippingStats) -> RGBChannel {
        if c.highR >= c.highG && c.highR >= c.highB { return .red }
        if c.highG >= c.highR && c.highG >= c.highB { return .green }
        return .blue
    }
}

// `nonisolated`: read by the deterministic feedback pass, which runs off-main.
nonisolated extension RGBChannel {
    var clippingName: String {
        switch self {
        case .red: String(localized: "red")
        case .green: String(localized: "green")
        case .blue: String(localized: "blue")
        }
    }
}

nonisolated extension FrameRegion {
    var clippingName: String {
        switch self {
        case .top: String(localized: "near the top of the frame")
        case .middle: String(localized: "in the middle of the frame")
        case .bottom: String(localized: "near the bottom of the frame")
        }
    }
}
