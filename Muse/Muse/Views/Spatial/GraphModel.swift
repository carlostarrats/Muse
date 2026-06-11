//
//  GraphModel.swift
//  Muse
//
//  Data assembly for the graph view. Membership = collections (hybrid
//  rule from spec §3); only members inside the current scope (folder /
//  collection filter / search results) are shown. Edges connect
//  collections sharing tags. Distances for the 3D spread come from the
//  stored Vision feature prints.
//

import Foundation
import GRDB
import Vision

struct GraphCluster: Identifiable, Equatable {
    let id: String            // collection id
    let name: String
    let memberPaths: [String] // alive + in scope, stable DB order
    let memberFileIDs: [String]
    let topTags: Set<String>
}

struct GraphData: Equatable {
    var clusters: [GraphCluster]
    var edges: [GraphEdge]     // indices into `clusters`
}

enum GraphModel {
    /// Build the overview model for the given in-scope absolute paths.
    static func build(queue: DatabaseQueue, scopePaths: [String]) async throws -> GraphData {
        guard !scopePaths.isEmpty else { return GraphData(clusters: [], edges: []) }
        let clusters: [GraphCluster] = try await queue.read { db in
            // scope path -> file id (chunked IN to stay under SQLite limits)
            var pathByFileID: [String: String] = [:]
            for chunk in stride(from: 0, to: scopePaths.count, by: 500).map({
                Array(scopePaths[$0..<min($0 + 500, scopePaths.count)])
            }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT file_id, absolute_path FROM paths
                    WHERE is_alive = 1 AND file_id IS NOT NULL
                      AND absolute_path IN (\(marks))
                    """, arguments: StatementArguments(chunk))
                for r in rows { pathByFileID[r["file_id"]] = r["absolute_path"] }
            }
            guard !pathByFileID.isEmpty else { return [] }

            let collectionRows = try CollectionRow
                .filter(Column("is_hidden") == 0)
                .fetchAll(db)
            var out: [GraphCluster] = []
            for c in collectionRows {
                let memberIDs = try String.fetchAll(db, sql: """
                    SELECT file_id FROM collection_members WHERE collection_id = ?
                    """, arguments: [c.id])
                let inScope = memberIDs.filter { pathByFileID[$0] != nil }
                guard !inScope.isEmpty else { continue }
                let marks = inScope.map { _ in "?" }.joined(separator: ",")
                let tags = try String.fetchAll(db, sql: """
                    SELECT label FROM tags
                    WHERE file_id IN (\(marks)) AND source != 'vision-color'
                    GROUP BY label ORDER BY COUNT(*) DESC LIMIT 10
                    """, arguments: StatementArguments(inScope))
                out.append(GraphCluster(
                    id: c.id, name: c.name,
                    memberPaths: inScope.compactMap { pathByFileID[$0] },
                    memberFileIDs: inScope,
                    topTags: Set(tags)))
            }
            // Biggest clusters first, ties broken by name for stable layouts.
            return out.sorted {
                if $0.memberPaths.count != $1.memberPaths.count {
                    return $0.memberPaths.count > $1.memberPaths.count
                }
                return $0.name < $1.name
            }
        }
        return GraphData(clusters: clusters,
                         edges: sharedTagEdges(tagsByCluster: clusters.map(\.topTags)))
    }

    /// One edge per cluster pair with ≥1 shared top tag.
    static func sharedTagEdges(tagsByCluster: [Set<String>]) -> [GraphEdge] {
        var edges: [GraphEdge] = []
        for i in 0..<tagsByCluster.count {
            for j in (i + 1)..<tagsByCluster.count {
                let shared = tagsByCluster[i].intersection(tagsByCluster[j]).count
                if shared >= 1 {
                    edges.append(GraphEdge(a: i, b: j, sharedTags: shared))
                }
            }
        }
        return edges
    }

    /// Stored feature prints for the given file ids (id -> archived print).
    static func featurePrints(queue: DatabaseQueue, fileIDs: [String]) async throws -> [String: Data] {
        try await queue.read { db in
            guard !fileIDs.isEmpty else { return [:] }
            var out: [String: Data] = [:]
            for chunk in stride(from: 0, to: fileIDs.count, by: 500).map({
                Array(fileIDs[$0..<min($0 + 500, fileIDs.count)])
            }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, feature_print FROM files
                    WHERE id IN (\(marks)) AND feature_print IS NOT NULL
                    """, arguments: StatementArguments(chunk))
                for r in rows { out[r["id"]] = r["feature_print"] }
            }
            return out
        }
    }

    /// Symmetric pairwise distance matrix. Pairs lacking a print get a
    /// neutral 1.0 (typical Vision print distances are ~0–2). CPU-bound:
    /// call off the main actor (Task.detached) for big clusters.
    static func distanceMatrix(prints: [Data?]) -> [[Float]] {
        let n = prints.count
        var matrix = [[Float]](repeating: [Float](repeating: 1.0, count: n), count: n)
        let observations: [VNFeaturePrintObservation?] = prints.map { data in
            guard let data else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self, from: data)
        }
        for i in 0..<n {
            matrix[i][i] = 0
            guard let a = observations[i] else { continue }
            for j in (i + 1)..<n {
                guard let b = observations[j] else { continue }
                var distance: Float = 1.0
                if (try? a.computeDistance(&distance, to: b)) != nil {
                    matrix[i][j] = distance
                    matrix[j][i] = distance
                }
            }
        }
        return matrix
    }
}
