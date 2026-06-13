//
//  CloudLayout.swift
//  Muse
//
//  Places N cards in a loose 3D BALL (editorial moodboard treatment). Cards
//  face the camera (billboarded by the view) while their positions sit at
//  varied depths, so orbiting the cluster swings the arrangement around and
//  reveals parallax. Deterministic per seed — stable across launches.
//

import Foundation
import simd

struct CloudCard {
    var position: SIMD3<Float>
    var w: CGFloat
    var h: CGFloat
}

enum CloudLayout {
    /// Ball radius scale; grows with ∛count so density stays roughly constant.
    static let radiusScale: Float = 150

    static func cards(count: Int, seed: UInt64) -> [CloudCard] {
        guard count > 0 else { return [] }
        var rng = SeededRandom(seed: seed)

        let radius = radiusScale * powf(Float(count), 1.0 / 3.0)
        let golden = Float.pi * (3 - sqrtf(5))   // ≈ 2.39996 rad

        var out: [CloudCard] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            // Even angular spread via a Fibonacci sphere direction…
            let t = (Float(i) + 0.5) / Float(count)
            let y = 1 - 2 * t
            let rxy = sqrtf(max(0, 1 - y * y))
            let phi = Float(i) * golden
            let dir = SIMD3<Float>(cos(phi) * rxy, y, sin(phi) * rxy)

            // …with a random radius (∛ for uniform volume) to fill the ball.
            let u = Float(Double.random(in: 0...1, using: &rng))
            let pos = dir * (radius * powf(u, 1.0 / 3.0))

            let w = CGFloat(Double.random(in: 130...240, using: &rng))
            let h = w * CGFloat(Double.random(in: 0.72...1.4, using: &rng))
            out.append(CloudCard(position: pos, w: w, h: h))
        }
        return out
    }
}
