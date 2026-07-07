//
//  StackScatter.swift
//  Muse
//
//  Pure geometry for the Collections page's scattered stack cards: a loose
//  pile of member images (cover on top) that fans apart on hover, mymind-
//  style. Given a stable seed (the collection id), a card count, and the
//  pile's cell size, produces each card's REST pose (tight pile, edges
//  peeking on all sides) and FAN pose (spread outward along the same
//  direction, bigger rotation). Deterministic: the same seed yields the
//  same pile forever — the scatter never reshuffles between hovers or
//  launches. No SwiftUI here; unit-tested in StackScatterTests.
//

import CoreGraphics
import Foundation

enum StackScatter {

    struct Pose: Equatable {
        var rotationDegrees: Double
        var offset: CGSize
        /// Card scale — 1 at rest; the fan shrinks cards a touch (video
        /// behavior) so the spread reads generous without traveling far.
        var scale: Double = 1
    }

    /// Fan-state shrink. Fixed constants, NOT rng draws: adding draws would
    /// shift the deterministic sequence and reshuffle every approved pile.
    static let topFanScale = 0.95
    static let underFanScale = 0.85

    /// One card's rest + fanned poses. Index 0 of `cards(...)` is the TOP
    /// card (the cover); later indices sit deeper in the pile.
    struct Card: Equatable {
        var rest: Pose
        var fan: Pose
    }

    /// Poses for a pile of `count` cards inside `cell`. The top card stays
    /// near center in both states (the video's pile anchors on its cover);
    /// under-cards get evenly-distributed, jittered directions so the pile
    /// peeks on all sides at rest and surrounds the cover when fanned.
    static func cards(seed: String, count: Int, cell: CGSize) -> [Card] {
        guard count > 0 else { return [] }
        var rng = SplitMix64(state: fnv1a(seed))
        let side = Double(min(cell.width, cell.height))

        // Top card: barely-off-center rotation, tiny offset; the fan lifts
        // it a touch and straightens it slightly.
        let topRotation = rng.range(1.5...3.5) * rng.sign()
        let topOffset = CGSize(width: rng.range(-1...1) * side * 0.015,
                               height: rng.range(-1...1) * side * 0.015)
        var out: [Card] = [Card(
            rest: Pose(rotationDegrees: topRotation, offset: topOffset),
            fan: Pose(rotationDegrees: topRotation * 0.6,
                      offset: CGSize(width: topOffset.width,
                                     height: topOffset.height - side * 0.05),
                      scale: topFanScale)
        )]

        // Under-cards: one angular sector each (jittered), so directions
        // surround the pile instead of clumping into a corner.
        let sectors = max(count - 1, 1)
        let sectorWidth = 2 * Double.pi / Double(sectors)
        let startAngle = rng.range(0...(2 * .pi))
        for i in 1..<count {
            let angle = startAngle
                + Double(i - 1) * sectorWidth
                + rng.range(-0.3...0.3) * sectorWidth
            let restMag = side * rng.range(0.03...0.10)
            let fanMag = side * rng.range(0.18...0.34)
            let fanAngle = angle + rng.range(-0.15...0.15)
            let spin = rng.sign()
            let restRotation = rng.range(2.0...7.0) * spin
            let fanRotation = rng.range(8.0...18.0) * spin
            out.append(Card(
                rest: Pose(rotationDegrees: restRotation,
                           offset: CGSize(width: cos(angle) * restMag,
                                          height: sin(angle) * restMag)),
                fan: Pose(rotationDegrees: fanRotation,
                          offset: CGSize(width: cos(fanAngle) * fanMag,
                                         height: sin(fanAngle) * fanMag),
                          scale: underFanScale)
            ))
        }
        return out
    }

    /// The pile's image paths, top card first: the chosen cover leads (even
    /// when it isn't in the fetched member page), then members in order with
    /// the cover deduped, repeated cyclically to `depth` when the collection
    /// has fewer unique images (a 1-image collection stacks that image behind
    /// itself). No members → empty (a stale cover alone doesn't make a pile).
    static func stackPaths(cover: String?, members: [String], depth: Int) -> [String] {
        guard depth > 0, !members.isEmpty else { return [] }
        var unique: [String] = []
        if let cover { unique.append(cover) }
        for m in members where !unique.contains(m) { unique.append(m) }
        var out: [String] = []
        var i = 0
        while out.count < depth {
            out.append(unique[i % unique.count])
            i += 1
        }
        return out
    }

    /// Scale an image to fit within a square `box` at its natural aspect
    /// ratio. Degenerate sizes fall back to the full square (grey card).
    static func fit(imageSize: CGSize, box: CGFloat) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: box, height: box)
        }
        if imageSize.width >= imageSize.height {
            return CGSize(width: box, height: box * imageSize.height / imageSize.width)
        }
        return CGSize(width: box * imageSize.width / imageSize.height, height: box)
    }

    // MARK: - Deterministic randomness

    /// FNV-1a over the seed string. NOT `Hasher` — that's randomized per
    /// launch, and the pile must look identical across launches.
    private static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        /// Uniform in [0, 1).
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func range(_ r: ClosedRange<Double>) -> Double {
            r.lowerBound + unit() * (r.upperBound - r.lowerBound)
        }
        mutating func sign() -> Double { next() & 1 == 0 ? 1 : -1 }
    }
}
