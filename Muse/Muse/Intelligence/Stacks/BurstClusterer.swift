//
//  BurstClusterer.swift
//  Muse
//
//  Time bucket FIRST, similarity second. Sort by captureAt, split into
//  sessions wherever the gap exceeds `sessionGapSeconds`, then union-find
//  WITHIN each session on feature-print similarity.
//
//  A session is physically small (a burst), so the inner O(k²) is trivial;
//  `maxSessionSize` defends against a pathological identical-timestamp
//  pile-up reintroducing n² by splitting oversized sessions at their largest
//  internal gaps.
//
//  A nil print never clusters, and `FeaturePrints.distance` refuses
//  length-mismatched pairs — prints from different Vision revisions must never
//  pair.
//

import Foundation

nonisolated enum BurstClusterer {
    static let sessionGapSeconds: Int64 = 10
    /// Named constant, not a literal. NOTE: never validated against a real
    /// burst library — owner validation outstanding.
    static let similarityThreshold: Float = 0.45
    static let maxSessionSize = 256

    struct Item: Sendable {
        let fileID: String
        let captureAt: Int64
        let print: [Float]?
    }

    static func clusters(_ items: [Item]) -> [[String]] {
        guard !items.isEmpty else { return [] }
        let sorted = items.sorted {
            $0.captureAt != $1.captureAt ? $0.captureAt < $1.captureAt : $0.fileID < $1.fileID
        }
        var captureAt: [String: Int64] = [:]
        for item in sorted { captureAt[item.fileID] = item.captureAt }

        var result: [[String]] = []
        for session in splitIntoSessions(sorted) {
            for bounded in splitOversized(session) {
                result.append(contentsOf: unionFindCluster(bounded))
            }
        }
        // Deterministic output: earliest member first, ties by first id.
        return result.sorted { a, b in
            let aFirst = a.compactMap { captureAt[$0] }.min() ?? 0
            let bFirst = b.compactMap { captureAt[$0] }.min() ?? 0
            return aFirst != bFirst ? aFirst < bFirst
                                    : (a.min() ?? "") < (b.min() ?? "")
        }
    }

    private static func splitIntoSessions(_ sorted: [Item]) -> [[Item]] {
        guard let first = sorted.first else { return [] }
        var sessions: [[Item]] = [[first]]
        for item in sorted.dropFirst() {
            let previous = sessions[sessions.count - 1].last!.captureAt
            if item.captureAt - previous > sessionGapSeconds {
                sessions.append([item])
            } else {
                sessions[sessions.count - 1].append(item)
            }
        }
        return sessions
    }

    /// Splits a session over `maxSessionSize` at its largest internal gap,
    /// recursively, until every piece is within bound.
    private static func splitOversized(_ session: [Item]) -> [[Item]] {
        guard session.count > maxSessionSize, session.count >= 2 else { return [session] }
        // Largest gap wins; ties break toward the MIDPOINT. Without the tie
        // rule, a run of evenly-spaced frames (every gap identical) splits at
        // index 1 and peels one item at a time — n recursions and one
        // still-oversized tail, i.e. no bound at all.
        let midpoint = session.count / 2
        var largestGapIndex = midpoint
        var largestGap: Int64 = .min
        for i in 1..<session.count {
            let gap = session[i].captureAt - session[i - 1].captureAt
            if gap > largestGap
                || (gap == largestGap && abs(i - midpoint) < abs(largestGapIndex - midpoint)) {
                largestGap = gap
                largestGapIndex = i
            }
        }
        let left = Array(session[..<largestGapIndex])
        let right = Array(session[largestGapIndex...])
        return splitOversized(left) + splitOversized(right)
    }

    private static func unionFindCluster(_ session: [Item]) -> [[String]] {
        guard session.count >= 2 else { return [] }
        var parent = Array(0..<session.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for i in 0..<session.count {
            guard let printI = session[i].print else { continue }
            for j in (i + 1)..<session.count {
                guard let printJ = session[j].print,
                      let distance = FeaturePrints.distance(printI, printJ),
                      distance <= similarityThreshold else { continue }
                union(i, j)
            }
        }
        var groups: [Int: [String]] = [:]
        for i in 0..<session.count {
            // A nil-print item never joins a group.
            guard session[i].print != nil else { continue }
            groups[find(i), default: []].append(session[i].fileID)
        }
        return groups.values.filter { $0.count >= 2 }.map { $0 }
    }
}
