//
//  GraphLayout.swift
//  Muse
//
//  Deterministic force-directed layout for the graph view's flat
//  overview: collections repel; shared-tag edges pull them together
//  (more shared tags -> shorter ideal length). Seeded by index order,
//  no RNG, fixed iterations -> identical output for identical input.
//

import Foundation
import simd

struct GraphEdge: Equatable {
    let a: Int
    let b: Int
    let sharedTags: Int
}

enum GraphLayout {
    /// Unit-space positions (max |coord| == 1 after normalization).
    static func positions(nodeCount: Int, edges: [GraphEdge],
                          iterations: Int = 250) -> [SIMD2<Double>] {
        guard nodeCount > 0 else { return [] }
        guard nodeCount > 1 else { return [SIMD2(0, 0)] }

        // Deterministic start: evenly spaced on a circle.
        var pos: [SIMD2<Double>] = (0..<nodeCount).map { i in
            let a = Double(i) / Double(nodeCount) * 2 * .pi
            return SIMD2(cos(a), sin(a))
        }

        let repulsion = 0.08
        for it in 0..<iterations {
            let step = 0.05 * (1 - Double(it) / Double(iterations))
            var force = [SIMD2<Double>](repeating: .zero, count: nodeCount)
            for i in 0..<nodeCount {
                for j in (i + 1)..<nodeCount {
                    var d = pos[i] - pos[j]
                    var len = simd_length(d)
                    if len < 1e-6 {
                        d = SIMD2(1e-3 * Double(i + 1), 1e-3)
                        len = simd_length(d)
                    }
                    let f = d / len * (repulsion / (len * len))
                    force[i] += f
                    force[j] -= f
                }
            }
            for e in edges where e.a < nodeCount && e.b < nodeCount && e.a != e.b {
                let d = pos[e.b] - pos[e.a]
                let len = max(simd_length(d), 1e-6)
                let ideal = 0.6 / (1 + 0.35 * Double(min(e.sharedTags, 4)))
                let f = d / len * (len - ideal) * 0.5
                force[e.a] += f
                force[e.b] -= f
            }
            for i in 0..<nodeCount {
                let l = simd_length(force[i])
                let capped = l > 0.2 ? force[i] / l * 0.2 : force[i]
                pos[i] += capped * step
            }
        }

        // Center, then normalize the longest axis to 1.
        let centroid = pos.reduce(SIMD2<Double>(), +) / Double(nodeCount)
        pos = pos.map { $0 - centroid }
        let maxAbs = pos.flatMap { [abs($0.x), abs($0.y)] }.max() ?? 1
        if maxAbs > 0 { pos = pos.map { $0 / maxAbs } }
        return pos
    }
}
