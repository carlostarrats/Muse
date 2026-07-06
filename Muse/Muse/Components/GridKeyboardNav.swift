//
//  GridKeyboardNav.swift
//  Muse
//
//  Pure keyboard-navigation math for the grid. Given the ordered masonry frame
//  array, the current highlighted index, and an arrow direction, returns the new
//  highlighted index (or nil for a no-op). Left/Right = ±1 in reading order,
//  wrapping across row boundaries, clamped at the ends. Up/Down = the masonry
//  rule: nearest row-band in that vertical direction, then the tile closest in
//  horizontal centre. No UI — unit tested, mirroring MasonryGeometry/GridSelection.
//

import CoreGraphics

enum GridKeyboardNav {
    enum Direction { case up, down, left, right }

    /// New highlighted index after an arrow press, or nil for a no-op (empty
    /// grid; a vertical move with no tile in that direction; a horizontal move
    /// already at the first/last tile). A nil `currentIndex` selects tile 0.
    static func next(currentIndex: Int?,
                     direction: Direction,
                     frames: [CGRect],
                     epsilon: CGFloat = 1,
                     bandTolerance: CGFloat) -> Int? {
        guard !frames.isEmpty else { return nil }
        guard let cur = currentIndex, cur >= 0, cur < frames.count else {
            return 0
        }
        switch direction {
        case .left:
            return cur > 0 ? cur - 1 : nil
        case .right:
            return cur < frames.count - 1 ? cur + 1 : nil
        case .down:
            return verticalTarget(from: cur, frames: frames,
                                  epsilon: epsilon, bandTolerance: bandTolerance,
                                  below: true)
        case .up:
            return verticalTarget(from: cur, frames: frames,
                                  epsilon: epsilon, bandTolerance: bandTolerance,
                                  below: false)
        }
    }

    private static func verticalTarget(from cur: Int,
                                       frames: [CGRect],
                                       epsilon: CGFloat,
                                       bandTolerance: CGFloat,
                                       below: Bool) -> Int? {
        let curTop = frames[cur].minY
        let curMidX = frames[cur].midX

        let candidates = frames.indices.filter { i in
            i != cur && (below ? frames[i].minY > curTop + epsilon
                               : frames[i].minY < curTop - epsilon)
        }
        guard !candidates.isEmpty else { return nil }

        let bandAnchor: CGFloat = below
            ? candidates.map { frames[$0].minY }.min()!
            : candidates.map { frames[$0].minY }.max()!

        let bandMembers = candidates.filter {
            abs(frames[$0].minY - bandAnchor) <= bandTolerance
        }

        return bandMembers.min { a, b in
            let da = abs(frames[a].midX - curMidX)
            let db = abs(frames[b].midX - curMidX)
            return da == db ? a < b : da < db
        }
    }
}
