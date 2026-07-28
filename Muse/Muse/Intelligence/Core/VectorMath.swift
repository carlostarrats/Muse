import Foundation
import Accelerate

nonisolated enum VectorMath {
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let n = vDSP_Length(a.count)
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, n)   // dot = a·b
        vDSP_svesq(a, 1, &na, n)          // na  = Σ aᵢ²
        vDSP_svesq(b, 1, &nb, n)          // nb  = Σ bᵢ²
        guard na > 0, nb > 0 else { return 0 }
        return Double(dot) / (Double(na).squareRoot() * Double(nb).squareRoot())
    }
    static func toData(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    static func fromData(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: - Batch similarity

    /// Pack `vectors` into a row-major `count x dimension` matrix with every row
    /// L2-normalized, so cosine similarity between two rows is just their dot
    /// product.
    ///
    /// Rows that are all-zero, empty, or the wrong length become all zeros —
    /// matching `cosine`'s zero-norm and length-mismatch guards, which both
    /// return 0. That equivalence is what lets `forEachPairAbove` stand in for
    /// an all-pairs `cosine` loop exactly.
    static func normalizedMatrix(_ vectors: [[Float]], dimension: Int) -> [Float] {
        guard dimension > 0 else { return [] }
        var out = [Float](repeating: 0, count: vectors.count * dimension)
        out.withUnsafeMutableBufferPointer { dst in
            for (i, v) in vectors.enumerated() {
                guard v.count == dimension else { continue }   // leaves zeros
                var sumsq: Float = 0
                vDSP_svesq(v, 1, &sumsq, vDSP_Length(dimension))
                guard sumsq > 0 else { continue }              // leaves zeros
                var inv = 1 / sumsq.squareRoot()
                v.withUnsafeBufferPointer { src in
                    vDSP_vsmul(src.baseAddress!, 1, &inv,
                               dst.baseAddress! + i * dimension, 1,
                               vDSP_Length(dimension))
                }
            }
        }
        return out
    }

    /// Call `body(i, j)` for every pair `i < j` whose cosine similarity is at
    /// least `threshold`.
    ///
    /// The similarities come from one `cblas_sgemm` per tile of rows rather than
    /// a scalar loop per pair. The clusterer's old inner loop called `cosine`
    /// once per pair, and `cosine` recomputes BOTH vectors' magnitudes every
    /// time — so each vector's norm was recomputed `count` times per pass.
    /// Normalizing once turns the whole thing into one matrix multiply.
    ///
    /// Tiling keeps the intermediate at `tileRows x count` floats instead of
    /// materializing the full `count x count` matrix (which is ~400 MB at 10k
    /// items). `tileRows` affects only memory, never the result.
    static func forEachPairAbove(threshold: Double,
                                 matrix: [Float],
                                 count: Int,
                                 dimension: Int,
                                 tileRows: Int = 512,
                                 _ body: (Int, Int) -> Void) {
        guard count > 1, dimension > 0, matrix.count >= count * dimension else { return }
        let tile = max(1, tileRows)
        let thresholdF = Float(threshold)
        var scratch = [Float](repeating: 0, count: tile * count)

        // Transpose ONCE (dimension x count) so each tile is a plain
        // non-transposed multiply. vDSP_mmul rather than cblas_sgemm: the CBLAS
        // entry point is deprecated from macOS 13.3 unless the whole target is
        // rebuilt with ACCELERATE_NEW_LAPACK, and a project-wide build flag is a
        // heavy price for one call site. Same vectorized hardware path.
        var transposed = [Float](repeating: 0, count: count * dimension)
        matrix.withUnsafeBufferPointer { m in
            transposed.withUnsafeMutableBufferPointer { t in
                guard let src = m.baseAddress, let dst = t.baseAddress else { return }
                vDSP_mtrans(src, 1, dst, 1, vDSP_Length(dimension), vDSP_Length(count))
            }
        }

        matrix.withUnsafeBufferPointer { m in
            transposed.withUnsafeBufferPointer { t in
                guard let base = m.baseAddress, let tBase = t.baseAddress else { return }
                var start = 0
                while start < count {
                    let rows = min(tile, count - start)
                    scratch.withUnsafeMutableBufferPointer { s in
                        guard let out = s.baseAddress else { return }
                        // S(rows x count) = A(rows x dim) * Mᵀ(dim x count)
                        vDSP_mmul(base + start * dimension, 1, tBase, 1, out, 1,
                                  vDSP_Length(rows), vDSP_Length(count), vDSP_Length(dimension))
                        for r in 0..<rows {
                            let i = start + r
                            let rowBase = r * count
                            // Only j > i — the similarity matrix is symmetric.
                            var j = i + 1
                            while j < count {
                                if out[rowBase + j] >= thresholdF { body(i, j) }
                                j += 1
                            }
                        }
                    }
                    start += rows
                }
            }
        }
    }
}
