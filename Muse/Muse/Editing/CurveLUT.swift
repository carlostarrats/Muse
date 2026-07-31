//
//  CurveLUT.swift
//  Muse
//
//  A point curve → a 1024-entry lookup table, via a monotone cubic
//  (Fritsch–Carlson) spline.
//
//  Monotone specifically: a plain cubic Hermite spline OVERSHOOTS between
//  control points, so a curve the user drew as strictly rising can dip on the
//  way up — visible as a band of inverted contrast in a smooth gradient. The
//  Fritsch–Carlson constraint bounds the tangents so the interpolant can never
//  reverse direction between two points.
//
//  Pure and CPU-side by design: this is the app's only display-referred stage,
//  it runs once per parameter change (not per pixel), and having it here means
//  the whole curve is unit-testable without a GPU.
//

import Foundation

nonisolated enum CurveLUT {
    static let entryCount = 1024

    /// Fewer than two points = identity ramp. Points are expected pre-sorted
    /// strictly increasing in x (`CurveParams.clamped()` guarantees it); this
    /// function does not re-sort or dedupe.
    static func build(points: [CurveParams.Point]) -> [Float] {
        let pts = sanitized(points)
        guard pts.count >= 2 else {
            return (0..<entryCount).map { Float($0) / Float(entryCount - 1) }
        }
        let xs = pts.map(\.x)
        let ys = pts.map(\.y)
        let n = xs.count

        var deltas = [Double](repeating: 0, count: n - 1)
        var secants = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            deltas[i] = xs[i + 1] - xs[i]
            secants[i] = deltas[i] > 0 ? (ys[i + 1] - ys[i]) / deltas[i] : 0
        }

        var tangents = [Double](repeating: 0, count: n)
        tangents[0] = secants[0]
        tangents[n - 1] = secants[n - 2]
        for i in 1..<(n - 1) {
            // A sign change (or a flat run) means a local extremum: the tangent
            // must be zero there or the spline overshoots past it.
            tangents[i] = secants[i - 1] * secants[i] <= 0
                ? 0
                : (secants[i - 1] + secants[i]) / 2
        }
        // Fritsch–Carlson: keep (α, β) inside the circle of radius 3, which is
        // the sufficient condition for monotonicity on each segment.
        for i in 0..<(n - 1) where secants[i] != 0 {
            let a = tangents[i] / secants[i]
            let b = tangents[i + 1] / secants[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / (s.squareRoot())
                tangents[i] = t * a * secants[i]
                tangents[i + 1] = t * b * secants[i]
            }
        }

        var lut = [Float](repeating: 0, count: entryCount)
        var segment = 0
        for i in 0..<entryCount {
            let x = Double(i) / Double(entryCount - 1)
            if x <= xs[0] { lut[i] = Float(ys[0]); continue }
            if x >= xs[n - 1] { lut[i] = Float(ys[n - 1]); continue }
            while segment < n - 2 && x > xs[segment + 1] { segment += 1 }
            let h = deltas[segment]
            let t = h > 0 ? (x - xs[segment]) / h : 0
            let t2 = t * t, t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            let y = h00 * ys[segment] + h10 * h * tangents[segment]
                  + h01 * ys[segment + 1] + h11 * h * tangents[segment + 1]
            lut[i] = Float(min(max(y, 0), 1))
        }
        return lut
    }

    /// Defensive: sort, clamp to the unit square, drop duplicate x (a zero-width
    /// segment divides by zero) and cap the count. The editor already enforces
    /// all of this, but a stack can also arrive from a sidecar or a backup.
    private static func sanitized(_ points: [CurveParams.Point]) -> [CurveParams.Point] {
        var out: [CurveParams.Point] = []
        for p in points.sorted(by: { $0.x < $1.x }) {
            let clamped = CurveParams.Point(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
            if let last = out.last, abs(last.x - clamped.x) < 1e-9 {
                out[out.count - 1] = clamped   // last wins, same as normalize
            } else {
                out.append(clamped)
            }
            if out.count == CurveParams.maxPoints { break }
        }
        return out
    }
}
