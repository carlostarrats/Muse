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

        for i in 0..<usable.count {
            for j in (i + 1)..<usable.count {
                let sim = VectorMath.cosine(usable[i].textVector!, usable[j].textVector!)
                if sim >= textThreshold { union(i, j) }
            }
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
