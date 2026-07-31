//
//  FeaturePrints.swift
//  Muse
//
//  files.feature_print stores the RAW VNFeaturePrintObservation.data element
//  buffer (VisionServices writes it, never an archive). A
//  VNFeaturePrintObservation cannot be reconstructed from that data —
//  NSKeyedUnarchiver on it always returns nil, which is why the duplicate
//  finder's "Visually similar" mode and SimilarTagSuggestions silently
//  returned nothing since they shipped. This compares the raw float buffers
//  directly: Euclidean distance over the same elements Vision's own
//  computeDistance would have used.
//

import Foundation
import Accelerate

nonisolated enum FeaturePrints {
    /// Reinterprets a raw element buffer as [Float]. nil when the byte count
    /// isn't a multiple of Float32's stride (corrupt/foreign data) or empty.
    static func floats(_ data: Data) -> [Float]? {
        let stride = MemoryLayout<Float>.stride
        guard !data.isEmpty, data.count % stride == 0 else { return nil }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    /// Euclidean distance via vDSP. nil when lengths differ — prints written
    /// by different Vision revisions must never be compared as if compatible.
    static func distance(_ a: [Float], _ b: [Float]) -> Float? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        var diff = [Float](repeating: 0, count: a.count)
        vDSP_vsub(b, 1, a, 1, &diff, 1, vDSP_Length(a.count))
        var sumSquares: Float = 0
        vDSP_svesq(diff, 1, &sumSquares, vDSP_Length(a.count))
        return sqrt(sumSquares)
    }
}
