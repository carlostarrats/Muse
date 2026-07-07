//
//  PartingField.swift
//  Muse
//
//  Pure math for the hero-open "parting" effect (reference: the Atlas
//  launch video, measured frame by frame). The read is a RIPPLE OF SIZE
//  radiating from the clicked tile: near neighbors shrink hard and clear
//  out of the hero's way, farther tiles shrink less and barely move, and
//  the far corners are almost untouched. Each tile's animation also starts
//  a beat later the farther out it sits (openDelay), so the effect
//  propagates outward like a wave instead of the whole grid sliding at
//  once. A fast fade (GridView applies it) carries the late part of the
//  motion — the reference's neighbors are mostly gone by ~0.15s.
//
//  No SwiftUI, no state: GridView applies scale/offset/fade per mounted
//  tile, value-scope-animated on the hero open/close signal. Unit-tested,
//  joining the pure-helper family (GridSelection, PageScroll,
//  MasonryGeometry, ReorderMath).
//

import Foundation
import CoreGraphics

enum PartingField {
    /// Peak outward displacement beside the hero. Deliberately below the
    /// reference's measured ~150: paired with the graded shrink, a stronger
    /// push opened arbitrary-looking gaps (owner feedback).
    static let maxPush: CGFloat = 110
    /// Exponential falloff length of the push — tight, local to the hero.
    static let decay: CGFloat = 300
    /// Peak shrink beside the hero (14%), fading with distance so the
    /// size-ripple dies out toward the corners.
    static let maxShrink: CGFloat = 0.14
    static let shrinkDecay: CGFloat = 450
    /// What non-source tiles fade to while parted (GridView applies it).
    static let partedOpacity: CGFloat = 0.15

    struct Displacement: Equatable {
        var offset: CGSize
        var scale: CGFloat
        /// Center distance from the clicked tile — drives openDelay.
        var distance: CGFloat
        static let identity = Displacement(offset: .zero, scale: 1, distance: 0)
    }

    /// How much of the full effect fixed-aspect (grid) layouts get. A regular
    /// lattice makes every deviation obvious — the same parting that reads
    /// organic in masonry's tight jigsaw reads exaggerated across uniform
    /// gutters (owner feedback) — so grid mode runs the identical motion at
    /// reduced amplitude.
    static let gridModeStrength: CGFloat = 0.7

    /// Displacement for `tileRect` while the tile at `clicked` is the open
    /// hero. Both rects must share a coordinate space (the masonry canvas).
    /// `strength` scales the whole effect (1 = masonry, gridModeStrength for
    /// fixed-aspect layouts). The clicked tile itself (any tile whose center
    /// coincides) is left untouched — it's the hero flight's source.
    static func displacement(for tileRect: CGRect, clicked: CGRect,
                             strength: CGFloat = 1) -> Displacement {
        let dx = Double(tileRect.midX - clicked.midX)
        let dy = Double(tileRect.midY - clicked.midY)
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0.5 else { return .identity }
        let k = Double(strength)
        let push = k * Double(maxPush) * exp(-distance / Double(decay))
        let scale = 1 - k * Double(maxShrink) * exp(-distance / Double(shrinkDecay))
        return Displacement(
            offset: CGSize(width: dx / distance * push, height: dy / distance * push),
            scale: CGFloat(scale),
            distance: CGFloat(distance))
    }

    /// Per-tile open-animation delay: the ripple propagates outward, one
    /// extra millisecond per ~15pt of distance, capped at 0.1s so the far
    /// corners still land inside the reference's ~0.3s envelope. Close is
    /// NOT staggered — everything converges together with the return flight.
    static func openDelay(distance: CGFloat) -> Double {
        Double(min(distance, 1500)) / 15_000
    }
}
