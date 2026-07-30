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

    /// The CLOSE converge spring (owner call, 2026-07-29): parted neighbors
    /// bounce back toward the landing image instead of easing flat. Damping
    /// below 1 is the bounce — lower it for more, raise toward 1 for less.
    /// Response stays under the 0.34s close flight so the grid has settled by
    /// the time the image lands on its tile.
    static let convergeResponse: Double = 0.26
    static let convergeDamping: Double = 0.60

    /// The close fade-in, animated SEPARATELY from the converge spring (see the
    /// note at GridView's tile `.animation`). Shorter than the spring on
    /// purpose: the tiles are back to full brightness early, so the bounce is
    /// watched at full opacity instead of happening while they're still faint.
    static let convergeFadeDuration: Double = 0.14

    /// Per-tile CLOSE stagger — the close counterpart to `openDelay`, and the
    /// reason the converge reads as a RAMP rather than one flat move: near
    /// neighbors snap back first and the far ones follow a beat later, so the
    /// bounce arrives as a wave and its apparent strength varies across the
    /// grid (owner: Atlas's "not consistent bounce... like a ramp up").
    ///
    /// Half the open stagger and capped tighter (0.05s vs 0.1s): the close
    /// flight is 0.34s and the last tile must still have settled by the
    /// landing, so the ramp has to fit in a much smaller envelope than open's.
    /// `PartingFieldTests` pins both properties — every close delay is ≤ its
    /// open delay, and cap + `convergeResponse` lands inside the 0.34s flight.
    static func closeDelay(distance: CGFloat) -> Double {
        min(Double(min(distance, 1500)) / 30_000, 0.05)
    }

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
    /// corners still land inside the reference's ~0.3s envelope. The close has
    /// its own, tighter stagger — see `closeDelay`.
    static func openDelay(distance: CGFloat) -> Double {
        Double(min(distance, 1500)) / 15_000
    }
}
