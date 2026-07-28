import XCTest
@testable import Muse

/// The clustering fast path must find EXACTLY the pairs the scalar cosine finds.
/// If any of these fail, users' collections have silently changed.
final class SimilarityMatrixTests: XCTestCase {

    private func randomVectors(count: Int, dim: Int, seed: UInt64) -> [[Float]] {
        var rng = seed
        func next() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int((rng >> 33) % 2000)) / 1000.0 - 1.0   // -1...1
        }
        return (0..<count).map { _ in (0..<dim).map { _ in next() } }
    }

    /// Vectors with genuine cluster structure: `groups` base directions, each
    /// with `count/groups` members perturbed by `noise`.
    ///
    /// Uniform random vectors are useless as a fixture here — in high dimensions
    /// they are near-orthogonal (concentration of measure), so essentially no
    /// pair clears a 0.62 threshold and an equivalence assertion would pass
    /// VACUOUSLY on two empty sets. Real embeddings are clustered; the fixture
    /// has to be too, or it tests nothing.
    private func clusteredVectors(count: Int, dim: Int, groups: Int,
                                  noise: Float, seed: UInt64) -> [[Float]] {
        var rng = seed
        func next() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int((rng >> 33) % 2000)) / 1000.0 - 1.0
        }
        let bases = (0..<groups).map { _ in (0..<dim).map { _ in next() } }
        return (0..<count).map { i in
            let base = bases[i % groups]
            return (0..<dim).map { d in base[d] + next() * noise }
        }
    }

    func testNormalizedRowsAreUnitLength() {
        let vs = randomVectors(count: 5, dim: 8, seed: 11)
        let m = VectorMath.normalizedMatrix(vs, dimension: 8)
        XCTAssertEqual(m.count, 5 * 8)
        for i in 0..<5 {
            let row = Array(m[(i * 8)..<((i + 1) * 8)])
            let norm = row.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
            XCTAssertEqual(norm, 1.0, accuracy: 1e-5)
        }
    }

    func testZeroAndWrongLengthRowsBecomeZero() {
        let vs: [[Float]] = [[0, 0, 0, 0], [1, 2], [1, 0, 0, 0]]
        let m = VectorMath.normalizedMatrix(vs, dimension: 4)
        XCTAssertEqual(Array(m[0..<4]), [0, 0, 0, 0], "zero vector stays zero")
        XCTAssertEqual(Array(m[4..<8]), [0, 0, 0, 0], "wrong-length vector is zeroed")
        XCTAssertEqual(Array(m[8..<12]), [1, 0, 0, 0])
    }

    /// The load-bearing test.
    func testMatchesScalarCosineReferenceExactly() {
        let n = 120, dim = 64, threshold = 0.62
        let vs = clusteredVectors(count: n, dim: dim, groups: 6, noise: 0.55, seed: 7)

        var expected = Set<String>()
        for i in 0..<n {
            for j in (i + 1)..<n where VectorMath.cosine(vs[i], vs[j]) >= threshold {
                expected.insert("\(i)-\(j)")
            }
        }

        var actual = Set<String>()
        let m = VectorMath.normalizedMatrix(vs, dimension: dim)
        VectorMath.forEachPairAbove(threshold: threshold, matrix: m,
                                    count: n, dimension: dim) { i, j in
            actual.insert("\(i)-\(j)")
        }

        XCTAssertFalse(expected.isEmpty, "fixture must actually produce some pairs")
        XCTAssertEqual(actual, expected)
    }

    /// Same, at a realistic embedding dimension and library size, with a
    /// threshold low enough to produce a lot of pairs.
    func testMatchesScalarReferenceAtRealisticScale() {
        let n = 300, dim = 512, threshold = 0.2
        let vs = clusteredVectors(count: n, dim: dim, groups: 8, noise: 0.9, seed: 20260728)

        var expected = Set<Int>()
        for i in 0..<n {
            for j in (i + 1)..<n where VectorMath.cosine(vs[i], vs[j]) >= threshold {
                expected.insert(i * n + j)
            }
        }
        var actual = Set<Int>()
        let m = VectorMath.normalizedMatrix(vs, dimension: dim)
        VectorMath.forEachPairAbove(threshold: threshold, matrix: m,
                                    count: n, dimension: dim) { i, j in
            actual.insert(i * n + j)
        }
        XCTAssertGreaterThan(expected.count, 50, "fixture must exercise many pairs")
        XCTAssertEqual(actual, expected)
    }

    /// Tiling must not change the answer — including a tile size that doesn't
    /// divide the row count evenly, and the degenerate tile of 1.
    func testTilingDoesNotChangeResults() {
        let n = 77, dim = 32, threshold = 0.5
        let vs = clusteredVectors(count: n, dim: dim, groups: 5, noise: 0.7, seed: 99)
        let m = VectorMath.normalizedMatrix(vs, dimension: dim)

        func pairs(tile: Int) -> Set<String> {
            var s = Set<String>()
            VectorMath.forEachPairAbove(threshold: threshold, matrix: m, count: n,
                                        dimension: dim, tileRows: tile) { i, j in
                s.insert("\(i)-\(j)")
            }
            return s
        }
        let reference = pairs(tile: 512)
        XCTAssertFalse(reference.isEmpty)
        XCTAssertEqual(reference, pairs(tile: 10))
        XCTAssertEqual(reference, pairs(tile: 1))
        XCTAssertEqual(reference, pairs(tile: 77))
        XCTAssertEqual(reference, pairs(tile: 76))
    }

    func testEmptyAndSingleAreSafe() {
        var called = 0
        VectorMath.forEachPairAbove(threshold: 0.5, matrix: [], count: 0, dimension: 4) { _, _ in called += 1 }
        XCTAssertEqual(called, 0)
        let one = VectorMath.normalizedMatrix([[1, 0, 0, 0]], dimension: 4)
        VectorMath.forEachPairAbove(threshold: 0.5, matrix: one, count: 1, dimension: 4) { _, _ in called += 1 }
        XCTAssertEqual(called, 0, "a single item has no pairs")
    }

    /// End-to-end: the clusterer must produce the same clusters the scalar loop
    /// produced. Reference computed here with the scalar cosine + same union-find.
    func testClustererMatchesScalarReference() {
        let n = 200, dim = 48
        let vs = clusteredVectors(count: n, dim: dim, groups: 7, noise: 0.6, seed: 4242)
        let items = vs.enumerated().map {
            ClusterItem(id: "f\($0.offset)", textVector: $0.element, featurePrint: nil)
        }
        let clusterer = HybridClusterer()

        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in 0..<n {
            for j in (i + 1)..<n where VectorMath.cosine(vs[i], vs[j]) >= clusterer.textThreshold {
                parent[find(i)] = find(j)
            }
        }
        var groups: [Int: [String]] = [:]
        for i in 0..<n { groups[find(i), default: []].append("f\(i)") }
        let expected = Set(groups.values
            .filter { $0.count >= clusterer.minClusterSize }
            .map { $0.sorted().joined(separator: ",") })

        let actual = Set(clusterer.cluster(items).map { $0.memberIDs.sorted().joined(separator: ",") })
        XCTAssertEqual(actual, expected)
    }

    /// Items without a text vector are dropped, and a set too small to cluster
    /// yields nothing — unchanged behaviour that the rewrite must not disturb.
    func testClustererGuardsAreUnchanged() {
        let clusterer = HybridClusterer()
        XCTAssertTrue(clusterer.cluster([]).isEmpty)
        let tooFew = (0..<3).map { ClusterItem(id: "f\($0)", textVector: [1, 0], featurePrint: nil) }
        XCTAssertTrue(clusterer.cluster(tooFew).isEmpty, "below minClusterSize")
        let noVectors = (0..<10).map { ClusterItem(id: "f\($0)", textVector: nil, featurePrint: nil) }
        XCTAssertTrue(clusterer.cluster(noVectors).isEmpty, "no usable vectors")
    }

    /// Identical vectors must all land in one cluster — a sanity check that the
    /// matmul path unions rather than merely computing similarities.
    func testIdenticalVectorsFormOneCluster() {
        let items = (0..<8).map {
            ClusterItem(id: "f\($0)", textVector: [0.3, 0.4, 0.5, 0.7], featurePrint: nil)
        }
        let clusters = HybridClusterer().cluster(items)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters.first?.memberIDs.count, 8)
    }
}
