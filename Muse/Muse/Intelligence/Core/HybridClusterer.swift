import Foundation

final class HybridClusterer: Clusterer {
    let modelVersion = "cluster-v1"
    let textThreshold = 0.62
    let minClusterSize = 4

    nonisolated func cluster(_ items: [ClusterItem]) -> [Cluster] {
        let usable = items.filter { $0.textVector != nil }
        guard usable.count >= minClusterSize else { return [] }
        var parent = Array(0..<usable.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }

        // One tiled matrix multiply instead of N^2 scalar cosines.
        //
        // The old loop called VectorMath.cosine per pair, and cosine recomputes
        // BOTH vectors' magnitudes every time — so each vector's norm was
        // recomputed `usable.count` times per pass, and this runs after every
        // analyze pass over the WHOLE library (50M pair comparisons at 10k
        // files). Normalizing once collapses cosine to a dot product.
        //
        // Same 0.62 threshold, same union-find — pinned against a scalar
        // reference by SimilarityMatrixTests at both the pair and cluster level.
        //
        // Agreement is exact EXCEPT for pairs sitting within ~3e-7 of the
        // threshold, where sgemm's Float accumulation and cosine's Double
        // division round to opposite sides of an exact tie. Measured at n=5000,
        // dim=512: 3 such pairs out of 12,497,500 (2.4e-7), each within 3.2e-7
        // of 0.62. At that distance the threshold is arbitrary anyway — the
        // embeddings are Float32 and 0.62 is hand-tuned — so this is not a
        // meaningful difference, but it is NOT bit-identical and shouldn't be
        // described that way.
        //
        // Do NOT swap this for incremental/centroid clustering: that IS a
        // different algorithm (no retroactive merge/split, order-dependent) and
        // its failure mode is silent quality drift.
        let dimension = usable[0].textVector!.count
        let matrix = VectorMath.normalizedMatrix(usable.map { $0.textVector! },
                                                 dimension: dimension)
        VectorMath.forEachPairAbove(threshold: textThreshold, matrix: matrix,
                                    count: usable.count, dimension: dimension) { i, j in
            union(i, j)
        }
        var groups: [Int: [String]] = [:]
        for (idx, it) in usable.enumerated() {
            groups[find(idx), default: []].append(it.id)
        }
        return groups.values
            .filter { $0.count >= minClusterSize }
            .map { Cluster(memberIDs: $0.sorted()) }
    }
}
