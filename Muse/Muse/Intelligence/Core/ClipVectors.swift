//
//  ClipVectors.swift
//  Muse
//
//  fp16 storage for CLIP's 512-d joint embedding space (50k photos ~50MB,
//  800k ~800MB on disk). `fromData` REFUSES an odd-length blob — vectors
//  from different model generations must never pair, the same class of rule
//  as FeaturePrints.distance's length-mismatch refusal.
//

import Foundation

nonisolated enum ClipVectors {
    static func toData(_ v: [Float]) -> Data {
        var data = Data(capacity: v.count * 2)
        for value in v {
            var half = Float16(value).bitPattern.littleEndian
            withUnsafeBytes(of: &half) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func fromData(_ d: Data) -> [Float]? {
        guard !d.isEmpty, d.count % 2 == 0 else { return nil }
        var out = [Float]()
        out.reserveCapacity(d.count / 2)
        d.withUnsafeBytes { raw in
            for i in stride(from: 0, to: raw.count, by: 2) {
                let bits = UInt16(raw[i]) | (UInt16(raw[i + 1]) << 8)
                out.append(Float(Float16(bitPattern: bits)))
            }
        }
        return out
    }
}

nonisolated enum ClipCentroid {
    /// Mean then re-normalize. nil for an empty input or a degenerate sum.
    static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let dimension = vectors.first?.count, dimension > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dimension)
        var counted = 0
        for v in vectors {
            guard v.count == dimension else { continue }
            for i in 0..<dimension { sum[i] += v[i] }
            counted += 1
        }
        guard counted > 0 else { return nil }
        var mean = sum.map { $0 / Float(counted) }
        let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        for i in 0..<dimension { mean[i] /= norm }
        return mean
    }
}
