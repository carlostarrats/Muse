//
//  CloudLayout.swift
//  Muse
//
//  Poses for N cards. Up to 25 cards use the measured reference poses
//  verbatim; beyond that the full set is generated with the same
//  statistics (spec: rx ±10–33°, ry ±5–30°, rz ±5–47°, sizes 4–10% of
//  canvas width, flowing band composition). Deterministic per seed.
//

import Foundation

enum CloudLayout {
    static func poses(count: Int, seed: UInt64) -> [CloudPose] {
        guard count > 0 else { return [] }
        if count <= CloudPose.measured.count {
            return Array(CloudPose.measured.prefix(count))
        }
        return generated(count: count, seed: seed)
    }

    private static func generated(count: Int, seed: UInt64) -> [CloudPose] {
        var rng = SeededRandom(seed: seed)
        // Flowing bands: enough rows to keep ~7 cards per band, serpentine
        // vertical wave along each band like the reference composition.
        let rows = max(3, Int(ceil(Double(count) / 7.0)))
        let cols = Int(ceil(Double(count) / Double(rows)))
        let marginX = CloudPose.refW * 0.07
        let marginY = CloudPose.refH * 0.13
        var out: [CloudPose] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let r = i / cols
            let c = i % cols
            let tx = cols > 1 ? Double(c) / Double(cols - 1) : 0.5
            let ty = rows > 1 ? Double(r) / Double(rows - 1) : 0.5
            let wave = sin(tx * .pi * 2.2 + Double(r) * 1.3) * (CloudPose.refH * 0.035)
            let cx = marginX + tx * (CloudPose.refW - 2 * marginX)
                + Double.random(in: -45...45, using: &rng)
            let cy = marginY + ty * (CloudPose.refH - 2 * marginY) + wave
                + Double.random(in: -35...35, using: &rng)
            let w = CloudPose.refW * Double.random(in: 0.04...0.10, using: &rng)
            let h = w * Double.random(in: 0.75...1.55, using: &rng)
            func signedAngle(_ range: ClosedRange<Double>) -> Double {
                let magnitude = Double.random(in: range, using: &rng)
                return Bool.random(using: &rng) ? magnitude : -magnitude
            }
            out.append(CloudPose(
                w: w, h: h,
                cx: min(max(cx, marginX * 0.5), CloudPose.refW - marginX * 0.5),
                cy: min(max(cy, marginY * 0.5), CloudPose.refH - marginY * 0.5),
                rx: signedAngle(10...33),
                ry: signedAngle(5...30),
                rz: signedAngle(5...47)
            ))
        }
        return out
    }
}
