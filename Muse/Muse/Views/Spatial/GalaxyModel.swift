//
//  GalaxyModel.swift
//  Muse
//
//  Data + layout engine for the Galaxy view. Gathers each in-scope image's
//  stored intelligence (Vision feature print, text embedding, palette, tags),
//  builds a BLENDED pairwise distance (look + meaning + color), projects it to
//  stable 3D positions, then derives cluster labels and nearest-neighbour
//  "constellation" edges. All heavy work runs off the main actor.
//

import Foundation
import GRDB
import Vision
import simd

struct GalaxyNode {
    let path: String
    let fileID: String
}

struct GalaxyLabel {
    let text: String
    let position: SIMD3<Float>   // unit-radius space, scaled by the view
}

struct GalaxyEdge {
    let a: Int
    let b: Int
}

struct GalaxyData {
    var nodes: [GalaxyNode]
    var positions: [SIMD3<Float>]   // parallel to nodes, unit-radius
    var edges: [GalaxyEdge]
    var labels: [GalaxyLabel]
    var totalInScope: Int           // before the render cap
    var wasCapped: Bool { nodes.count < totalInScope }

    static let empty = GalaxyData(nodes: [], positions: [], edges: [],
                                  labels: [], totalInScope: 0)

    /// Stable string used to decide whether the scene must be rebuilt.
    var identity: String {
        nodes.map(\.path).joined(separator: "|") + "#\(nodes.count)"
    }
}

enum GalaxyModel {
    // Blend weights — look vs meaning vs color. Tune by feel.
    static let visualWeight: Float = 0.5
    static let semanticWeight: Float = 0.4
    static let colorWeight: Float = 0.1

    /// O(n²) cap. Above this we render the first N in scope (the caller passes
    /// them in the grid's order, i.e. most-recent first) and report the rest.
    static let renderCap = 1000

    /// A constellation edge is drawn only for neighbours closer than this.
    static let edgeThreshold: Float = 0.55
    static let maxEdges = 400

    // MARK: - Build

    static func build(queue: DatabaseQueue, scopePaths: [String]) async throws -> GalaxyData {
        let total = scopePaths.count
        guard total > 0 else { return .empty }
        let capped = Array(scopePaths.prefix(renderCap))

        // 1. Resolve paths -> file ids, then fetch stored intelligence.
        let fetched = try await queue.read { db -> Fetched in
            var fileIDByPath: [String: String] = [:]
            for chunk in chunks(capped, 500) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT file_id, absolute_path FROM paths
                    WHERE is_alive = 1 AND file_id IS NOT NULL
                      AND absolute_path IN (\(marks))
                    """, arguments: StatementArguments(chunk))
                for r in rows {
                    if let fid: String = r["file_id"], let p: String = r["absolute_path"] {
                        fileIDByPath[p] = fid
                    }
                }
            }
            // Keep caller order; drop paths with no file row.
            let ordered: [(path: String, fileID: String)] = capped.compactMap { p in
                fileIDByPath[p].map { (p, $0) }
            }
            guard !ordered.isEmpty else { return Fetched.empty }

            let ids = ordered.map(\.fileID)
            var printByID: [String: Data] = [:]
            var paletteByID: [String: String] = [:]
            for chunk in chunks(ids, 500) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, feature_print, palette FROM files
                    WHERE id IN (\(marks))
                    """, arguments: StatementArguments(chunk))
                for r in rows {
                    let id: String = r["id"]
                    if let d: Data = r["feature_print"] { printByID[id] = d }
                    if let p: String = r["palette"] { paletteByID[id] = p }
                }
            }

            var vectorByID: [String: Data] = [:]
            for chunk in chunks(ids, 500) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT file_id, vector FROM embeddings
                    WHERE file_id IN (\(marks))
                    """, arguments: StatementArguments(chunk))
                for r in rows { vectorByID[r["file_id"]] = r["vector"] }
            }

            return Fetched(ordered: ordered, printByID: printByID,
                           paletteByID: paletteByID, vectorByID: vectorByID)
        }

        guard fetched.ordered.count > 1 else {
            // 0 or 1 usable images — nothing to arrange.
            let nodes = fetched.ordered.map { GalaxyNode(path: $0.path, fileID: $0.fileID) }
            return GalaxyData(nodes: nodes,
                              positions: nodes.isEmpty ? [] : [SIMD3(0, 0, 0)],
                              edges: [], labels: [], totalInScope: total)
        }

        // 2. Heavy compute off the main actor.
        let ordered = fetched.ordered
        let seed = SeededRandom.fnv1a(ordered.map(\.fileID))
        return await Task.detached(priority: .userInitiated) {
            assemble(fetched: fetched, total: total, seed: seed)
        }.value
    }

    // MARK: - Off-main assembly

    private struct Fetched {
        var ordered: [(path: String, fileID: String)]
        var printByID: [String: Data]
        var paletteByID: [String: String]
        var vectorByID: [String: Data]
        static let empty = Fetched(ordered: [], printByID: [:], paletteByID: [:],
                                   vectorByID: [:])
    }

    private static func assemble(fetched: Fetched, total: Int, seed: UInt64) -> GalaxyData {
        let ordered = fetched.ordered
        let n = ordered.count

        let observations: [VNFeaturePrintObservation?] = ordered.map { item in
            guard let d = fetched.printByID[item.fileID] else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self, from: d)
        }
        let embeddings: [[Float]] = ordered.map { item in
            guard let d = fetched.vectorByID[item.fileID] else { return [] }
            return VectorMath.fromData(d)
        }
        let palettes: [[SIMD3<Float>]] = ordered.map { item in
            paletteColors(fetched.paletteByID[item.fileID])
        }

        // Raw component matrices (flat, NaN = missing for that pair).
        let nan = Float.nan
        var visual = [Float](repeating: nan, count: n * n)
        var semantic = [Float](repeating: nan, count: n * n)
        var color = [Float](repeating: nan, count: n * n)
        var sumV: Float = 0, cntV = 0
        var sumS: Float = 0, cntS = 0
        var sumC: Float = 0, cntC = 0

        for i in 0..<n {
            for j in (i + 1)..<n {
                if let oa = observations[i], let ob = observations[j] {
                    var d: Float = 0
                    if (try? oa.computeDistance(&d, to: ob)) != nil {
                        visual[i * n + j] = d; sumV += d; cntV += 1
                    }
                }
                if let s = semanticDistance(embeddings[i], embeddings[j]) {
                    semantic[i * n + j] = s; sumS += s; cntS += 1
                }
                if let c = paletteDistance(palettes[i], palettes[j]) {
                    color[i * n + j] = c; sumC += c; cntC += 1
                }
            }
        }
        let meanV = cntV > 0 ? sumV / Float(cntV) : 1
        let meanS = cntS > 0 ? sumS / Float(cntS) : 1
        let meanC = cntC > 0 ? sumC / Float(cntC) : 1

        // Blend (each component normalised to mean ≈ 1, weights renormalised
        // by which components are present for that pair).
        var blended = [[Float]](repeating: [Float](repeating: 1, count: n), count: n)
        for i in 0..<n {
            blended[i][i] = 0
            for j in (i + 1)..<n {
                var acc: Float = 0, wsum: Float = 0
                let v = visual[i * n + j]
                if !v.isNaN, meanV > 0 { acc += visualWeight * (v / meanV); wsum += visualWeight }
                let s = semantic[i * n + j]
                if !s.isNaN, meanS > 0 { acc += semanticWeight * (s / meanS); wsum += semanticWeight }
                let c = color[i * n + j]
                if !c.isNaN, meanC > 0 { acc += colorWeight * (c / meanC); wsum += colorWeight }
                let value = wsum > 0 ? acc / wsum : 1
                blended[i][j] = value
                blended[j][i] = value
            }
        }

        // 3D projection — fewer iterations for big sets to stay responsive.
        let iterations = n > 600 ? 120 : 200
        let raw = SimilarityLayout.positions(distances: blended, seed: seed,
                                             iterations: iterations)
        let positions = raw.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }

        let nodes = ordered.map { GalaxyNode(path: $0.path, fileID: $0.fileID) }
        let edges = constellationEdges(blended: blended)

        return GalaxyData(nodes: nodes, positions: positions,
                          edges: edges, labels: [], totalInScope: total)
    }

    // MARK: - Constellation edges

    private static func constellationEdges(blended: [[Float]]) -> [GalaxyEdge] {
        let n = blended.count
        guard n > 1 else { return [] }
        var seen = Set<Int>()           // a * n + b, a < b
        var candidates: [(Int, Int, Float)] = []
        for i in 0..<n {
            var best = -1, bestD = Float.greatestFiniteMagnitude
            for j in 0..<n where j != i {
                if blended[i][j] < bestD { bestD = blended[i][j]; best = j }
            }
            if best >= 0, bestD < edgeThreshold {
                let a = min(i, best), b = max(i, best)
                if seen.insert(a * n + b).inserted {
                    candidates.append((a, b, bestD))
                }
            }
        }
        return candidates.sorted { $0.2 < $1.2 }
            .prefix(maxEdges)
            .map { GalaxyEdge(a: $0.0, b: $0.1) }
    }

    // MARK: - Component distances

    private static func semanticDistance(_ a: [Float], _ b: [Float]) -> Float? {
        guard !a.isEmpty, !b.isEmpty, a.count == b.count else { return nil }
        return Float(max(0, 1 - VectorMath.cosine(a, b)))
    }

    private static func paletteDistance(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float? {
        guard !a.isEmpty, !b.isEmpty else { return nil }
        func avgMin(_ from: [SIMD3<Float>], _ to: [SIMD3<Float>]) -> Float {
            var sum: Float = 0
            for c in from {
                var m = Float.greatestFiniteMagnitude
                for d in to { m = min(m, simd_distance(c, d)) }
                sum += m
            }
            return sum / Float(from.count)
        }
        // RGB distance max is sqrt(3); normalise to ~0–1.
        return 0.5 * (avgMin(a, b) + avgMin(b, a)) / 1.7320508
    }

    private static func paletteColors(_ json: String?) -> [SIMD3<Float>] {
        guard let json, let data = json.data(using: .utf8),
              let hexes = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return hexes.compactMap(rgb(fromHex:))
    }

    private static func rgb(fromHex hex: String) -> SIMD3<Float>? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return SIMD3(Float((value >> 16) & 0xFF) / 255,
                     Float((value >> 8) & 0xFF) / 255,
                     Float(value & 0xFF) / 255)
    }

    private static func chunks<T>(_ array: [T], _ size: Int) -> [[T]] {
        stride(from: 0, to: array.count, by: size).map {
            Array(array[$0..<min($0 + size, array.count)])
        }
    }
}
