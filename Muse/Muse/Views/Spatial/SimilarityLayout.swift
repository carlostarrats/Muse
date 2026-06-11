//
//  SimilarityLayout.swift
//  Muse
//
//  Spec §3 graph zoom-in: spread a cluster's images in 3D positioned by
//  visual similarity (feature-print distance). Simple iterative stress
//  relaxation over the pairwise distance matrix — deterministic per
//  seed, output centered and normalized to unit radius.
//

import Foundation
import simd

enum SimilarityLayout {
    static func positions(distances: [[Float]], seed: UInt64,
                          iterations: Int = 200) -> [SIMD3<Double>] {
        let n = distances.count
        guard n > 0 else { return [] }
        guard n > 1 else { return [SIMD3(0, 0, 0)] }

        var rng = SeededRandom(seed: seed)
        var pos: [SIMD3<Double>] = (0..<n).map { _ in
            SIMD3(Double.random(in: -1...1, using: &rng),
                  Double.random(in: -1...1, using: &rng),
                  Double.random(in: -1...1, using: &rng))
        }

        // Normalize target distances to mean 1 (scale-free input).
        var sum = 0.0
        var count = 0
        for i in 0..<n {
            for j in (i + 1)..<n {
                sum += Double(distances[i][j])
                count += 1
            }
        }
        let mean = (count > 0 && sum > 0) ? sum / Double(count) : 1

        for it in 0..<iterations {
            let step = 0.12 * (1 - Double(it) / Double(iterations))
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let target = Double(distances[i][j]) / mean
                    var d = pos[i] - pos[j]
                    var len = simd_length(d)
                    if len < 1e-9 {
                        d = SIMD3(1e-3, 0, 0)
                        len = 1e-3
                    }
                    let delta = (len - target) / len * step * 0.5
                    pos[i] -= d * delta
                    pos[j] += d * delta
                }
            }
        }

        let centroid = pos.reduce(SIMD3<Double>(), +) / Double(n)
        pos = pos.map { $0 - centroid }
        let maxLen = pos.map(simd_length).max() ?? 1
        if maxLen > 0 { pos = pos.map { $0 / maxLen } }
        return pos
    }
}
