//
//  DuplicateFinder.swift
//  Muse
//
//  Three clusterers run in parallel. EVERY group gets exactly one suggested
//  keeper — see `keeperIndex`. The original Q12 rule (suggest only where the
//  signal is rock solid, so a filename group or a same-resolution visual group
//  got no suggestion) was reversed by the owner 2026-08-01: with no keeper the
//  review modal drew a green KEEP badge on every copy and pre-marked nothing,
//  which reads as "the finder didn't work", not as "you decide". The
//  suggestion is a default the user can freely override, and
//  DuplicateDeleteRules still guarantees a group can never be fully deleted.
//
//  Visual scope defaults to current folder per the §4 vector index
//  scaling rules. "Everywhere" mode runs in the background with
//  progress.
//

import Foundation
import GRDB

struct DuplicateGroup: Identifiable, Hashable {
    let id: UUID
    let reason: Reason
    let members: [Member]

    struct Member: Hashable {
        let url: URL
        let fileID: String?
        let sizeBytes: Int64
        let width: Int?
        let height: Int?
        let isSuggestedKeeper: Bool
    }

    enum Reason: String {
        case byteExact, visual, filename
        var displayName: String {
            switch self {
            case .byteExact: return String(localized: "Byte-exact")
            case .visual:    return String(localized: "Visually similar")
            case .filename:  return String(localized: "Same filename")
            }
        }
    }
}

@MainActor
final class DuplicateFinder: ObservableObject {
    static let shared = DuplicateFinder()
    private init() {}

    @Published var isRunning: Bool = false
    @Published var progress: Double = 0
    @Published var groups: [DuplicateGroup] = []

    /// Run all three clusterers against the given URLs (current-folder scope).
    /// Returns merged groups, also stored on `groups` for UI consumption.
    func scan(in urls: [URL]) async {
        isRunning = true
        progress = 0
        defer { isRunning = false; progress = 0 }
        groups = []

        // 1. Byte-exact (uses indexed content_hash)
        let byteExact = await byteExactGroups(urls: urls)
        groups += byteExact
        progress = 0.33

        // 2. Filename groups
        let byName = filenameGroups(urls: urls)
        groups += byName
        progress = 0.66

        // 3. Visual (feature print clustering, current-folder scope)
        let visual = await visualGroups(urls: urls)
        groups += visual
        progress = 1.0
    }

    // MARK: - Byte-exact

    private func byteExactGroups(urls: [URL]) async -> [DuplicateGroup] {
        guard let queue = Database.shared.dbQueue else { return [] }
        let absPaths = urls.map { $0.standardizedFileURL.path }
        let rows: [(PathRow, FileRow)] = (try? await queue.read { db -> [(PathRow, FileRow)] in
            guard !absPaths.isEmpty else { return [] }
            let placeholders = absPaths.map { _ in "?" }.joined(separator: ",")
            let pathRows = try PathRow.fetchAll(
                db,
                sql: "SELECT * FROM paths WHERE absolute_path IN (\(placeholders)) AND is_alive = 1",
                arguments: StatementArguments(absPaths)
            )
            let fileIDs = pathRows.compactMap { $0.file_id }
            guard !fileIDs.isEmpty else { return [] }
            let fileRows = try FileRow.filter(fileIDs.contains(FileRow.Columns.id)).fetchAll(db)
            let byID = Dictionary(uniqueKeysWithValues: fileRows.map { ($0.id, $0) })
            return pathRows.compactMap { p in
                guard let fid = p.file_id, let f = byID[fid] else { return nil }
                return (p, f)
            }
        }) ?? []

        // Group by content_hash
        var byHash: [String: [(PathRow, FileRow)]] = [:]
        for (p, f) in rows {
            guard let h = f.content_hash else { continue }
            byHash[h, default: []].append((p, f))
        }

        return byHash.values
            .filter { $0.count > 1 }
            .map { items in
                let members = scoreByteExactKeepers(items: items)
                return DuplicateGroup(id: UUID(), reason: .byteExact, members: members)
            }
    }

    /// One copy of a duplicate group, reduced to what the keeper choice needs —
    /// so all three clusterers pick a keeper by the same rule regardless of what
    /// they happen to know about their members.
    nonisolated struct KeeperCandidate {
        let path: String
        /// Pixel count, or 0 when the dimensions aren't known (the filename
        /// clusterer reads nothing from the DB). Unknown compares as a tie, so
        /// the decision falls through to bytes and then path quality.
        let pixels: Int
        let sizeBytes: Int64
        let createdAt: Int64?
    }

    /// Which copy to keep. TOTAL and deterministic: every non-empty group gets
    /// exactly one keeper, so the review modal never shows a group where every
    /// tile says KEEP and nothing is pre-marked.
    ///
    /// Ordered by decreasing confidence: more pixels (never throw away
    /// resolution), then more bytes (the less-recompressed copy at equal
    /// resolution), then path quality, then the path itself so the result is
    /// stable across scans rather than dependent on row order.
    nonisolated static func keeperIndex(_ candidates: [KeeperCandidate]) -> Int? {
        guard !candidates.isEmpty else { return nil }
        return candidates.indices.max { a, b in
            let (x, y) = (candidates[a], candidates[b])
            if x.pixels != y.pixels { return x.pixels < y.pixels }
            if x.sizeBytes != y.sizeBytes { return x.sizeBytes < y.sizeBytes }
            let (sx, sy) = (pathScore(x), pathScore(y))
            if sx != sy { return sx < sy }
            return x.path > y.path      // ascending path wins the final tie
        }
    }

    /// Path-quality heuristic: cleaner basename, shorter path, not in
    /// Downloads/Desktop/Trash, older creation date (usually the original).
    private nonisolated static func pathScore(_ c: KeeperCandidate) -> Double {
        var score = 0.0
        let abs = c.path
        // Prefer cleaner basenames
        let base = (abs as NSString).lastPathComponent
        if base.contains(" copy") || base.contains("(") || base.contains("(1)") {
            score -= 5
        }
        // Prefer shorter paths
        let depth = (abs as NSString).pathComponents.count
        score -= Double(depth) * 0.1
        // Penalize Downloads/Desktop/Trash
        let lower = abs.lowercased()
        if lower.contains("/downloads/") { score -= 3 }
        if lower.contains("/desktop/") { score -= 1 }
        if lower.contains(".trash/") { score -= 50 }
        // Older creation date is usually the original
        if let created = c.createdAt {
            score -= Double(created) / 1e10
        }
        return score
    }

    /// Byte-exact members. Every copy is the same bytes, so pixels and size tie
    /// and the keeper comes down to path quality.
    private func scoreByteExactKeepers(items: [(PathRow, FileRow)]) -> [DuplicateGroup.Member] {
        let best = Self.keeperIndex(items.map { (path, file) in
            KeeperCandidate(path: path.absolute_path,
                            pixels: (file.width ?? 0) * (file.height ?? 0),
                            sizeBytes: file.size_bytes ?? 0,
                            createdAt: file.created_at)
        })
        return items.enumerated().map { (i, item) in
            let (path, file) = item
            return DuplicateGroup.Member(
                url: URL(fileURLWithPath: path.absolute_path),
                fileID: path.file_id,
                sizeBytes: file.size_bytes ?? 0,
                width: file.width,
                height: file.height,
                isSuggestedKeeper: i == best
            )
        }
    }

    // MARK: - Filename

    private func filenameGroups(urls: [URL]) -> [DuplicateGroup] {
        let groups = Dictionary(grouping: urls, by: { $0.lastPathComponent })
        return groups.values
            .filter { $0.count > 1 }
            .map { urls in
                // Dimensions aren't loaded here (no DB read), so the keeper
                // comes down to bytes then path quality.
                let sizes = urls.map { url in
                    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        .flatMap { Int64($0) } ?? 0
                }
                let best = Self.keeperIndex(zip(urls, sizes).map { url, size in
                    KeeperCandidate(path: url.standardizedFileURL.path, pixels: 0,
                                    sizeBytes: size, createdAt: nil)
                })
                let members = zip(urls, sizes).enumerated().map { i, pair in
                    DuplicateGroup.Member(
                        url: pair.0,
                        fileID: nil,
                        sizeBytes: pair.1,
                        width: nil,
                        height: nil,
                        isSuggestedKeeper: i == best
                    )
                }
                return DuplicateGroup(id: UUID(), reason: .filename, members: members)
            }
    }

    // MARK: - Visual

    private func visualGroups(urls: [URL]) async -> [DuplicateGroup] {
        guard let queue = Database.shared.dbQueue else { return [] }
        let absPaths = urls.map { $0.standardizedFileURL.path }
        let entries: [(PathRow, FileRow)] = (try? await queue.read { db -> [(PathRow, FileRow)] in
            guard !absPaths.isEmpty else { return [] }
            let placeholders = absPaths.map { _ in "?" }.joined(separator: ",")
            let pathRows = try PathRow.fetchAll(
                db,
                sql: "SELECT * FROM paths WHERE absolute_path IN (\(placeholders)) AND is_alive = 1",
                arguments: StatementArguments(absPaths)
            )
            let fileIDs = pathRows.compactMap { $0.file_id }
            guard !fileIDs.isEmpty else { return [] }
            let fileRows = try FileRow.filter(fileIDs.contains(FileRow.Columns.id)).fetchAll(db)
            let byID = Dictionary(uniqueKeysWithValues: fileRows.map { ($0.id, $0) })
            return pathRows.compactMap { p in
                guard let fid = p.file_id, let f = byID[fid] else { return nil }
                guard f.feature_print != nil else { return nil }
                return (p, f)
            }
        }) ?? []

        if entries.count < 2 { return [] }

        // feature_print holds the RAW VNFeaturePrintObservation.data element
        // buffer — it was never archived, so the NSKeyedUnarchiver this used
        // to do returned nil for every row and this whole mode was dead.
        // Compare the raw float buffers instead (FeaturePrints).
        let printed: [(PathRow, FileRow, [Float])] = entries.compactMap { (p, f) in
            guard let data = f.feature_print,
                  let floats = FeaturePrints.floats(data) else { return nil }
            return (p, f, floats)
        }

        let items = printed.map { (p, f, floats) in
            VisualItem(id: p.id,
                       floats: floats,
                       area: (f.width ?? 0) * (f.height ?? 0),
                       colorPrefix: String((f.dominant_color ?? "").prefix(4)))
        }

        return DuplicateFinder.visualGroupIndices(items).map { indices in
            let cluster = indices.map { printed[$0] }
            let members = scoreVisualKeepers(items: cluster)
            return DuplicateGroup(id: UUID(), reason: .visual, members: members)
        }
    }

    /// One candidate for visual grouping, reduced to exactly what the pure
    /// grouping pass needs. Extracted so the grouping is testable with
    /// synthesized prints — this path shipped dead once and stays pinned.
    nonisolated struct VisualItem {
        let id: String
        let floats: [Float]
        let area: Int
        let colorPrefix: String
    }

    /// Smaller distance = more similar.
    nonisolated static let visualDistanceThreshold: Float = 0.45

    /// Pre-filter by resolution bucket (within ±10%) and dominant color hex
    /// prefix, then brute-force distance on the survivors. Returns clusters of
    /// indices into `items` (only clusters of 2+).
    nonisolated static func visualGroupIndices(_ items: [VisualItem]) -> [[Int]] {
        struct Bucket: Hashable {
            let kindBucket: Int
            let colorPrefix: String
        }
        func bucketFor(_ item: VisualItem) -> Bucket {
            // Discretize area into ±10% bins via log
            let bin = item.area > 0 ? Int(log(Double(item.area)) / log(1.21)) : 0
            return Bucket(kindBucket: bin, colorPrefix: item.colorPrefix)
        }

        let bucketed = Dictionary(grouping: items.indices, by: { bucketFor(items[$0]) })

        var clusters: [[Int]] = []
        var visited = Set<String>()
        for (_, candidates) in bucketed where candidates.count >= 2 {
            let candidates = Array(candidates)
            for i in 0..<candidates.count {
                let key = items[candidates[i]].id
                if visited.contains(key) { continue }
                var cluster: [Int] = [candidates[i]]
                visited.insert(key)
                for j in (i+1)..<candidates.count {
                    let otherKey = items[candidates[j]].id
                    if visited.contains(otherKey) { continue }
                    guard let distance = FeaturePrints.distance(items[candidates[i]].floats,
                                                               items[candidates[j]].floats)
                    else { continue }
                    if distance < visualDistanceThreshold {
                        cluster.append(candidates[j])
                        visited.insert(otherKey)
                    }
                }
                if cluster.count >= 2 {
                    clusters.append(cluster)
                }
            }
        }
        return clusters
    }

    /// Visually-similar members: highest resolution wins, and at equal
    /// resolution (the common near-identical-export case) the larger file, then
    /// path quality — rather than the old "no gap → no suggestion at all".
    private func scoreVisualKeepers(items: [(PathRow, FileRow, [Float])]) -> [DuplicateGroup.Member] {
        let best = Self.keeperIndex(items.map { (path, file, _) in
            KeeperCandidate(path: path.absolute_path,
                            pixels: (file.width ?? 0) * (file.height ?? 0),
                            sizeBytes: file.size_bytes ?? 0,
                            createdAt: file.created_at)
        })
        return items.enumerated().map { (i, item) in
            let (path, file, _) = item
            return DuplicateGroup.Member(
                url: URL(fileURLWithPath: path.absolute_path),
                fileID: path.file_id,
                sizeBytes: file.size_bytes ?? 0,
                width: file.width,
                height: file.height,
                isSuggestedKeeper: i == best
            )
        }
    }
}
