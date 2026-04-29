//
//  DuplicateFinder.swift
//  Muse
//
//  Three clusterers run in parallel. Smart suggestions only where
//  signal is rock solid (Q12):
//  - Byte-exact: smart-suggest a keeper based on path quality, name
//    cleanliness, age.
//  - Visual: smart-suggest only when resolution gap exceeds 10% (keep
//    higher-res). Otherwise no suggestion.
//  - Filename-only: no suggestion.
//
//  Visual scope defaults to current folder per the §4 vector index
//  scaling rules. "Everywhere" mode runs in the background with
//  progress.
//

import Foundation
import Vision
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
            case .byteExact: return "Byte-exact"
            case .visual:    return "Visually similar"
            case .filename:  return "Same filename"
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

    /// Pick the highest-confidence keeper — shorter path, cleaner basename,
    /// older creation date, not in Downloads/Desktop/Trash. Q12 rock-solid.
    private func scoreByteExactKeepers(items: [(PathRow, FileRow)]) -> [DuplicateGroup.Member] {
        let scored = items.map { (path, file) -> (PathRow, FileRow, Double) in
            var score = 0.0
            let abs = path.absolute_path
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
            if let created = file.created_at {
                score -= Double(created) / 1e10
            }
            return (path, file, score)
        }
        guard let best = scored.max(by: { $0.2 < $1.2 }) else {
            return items.map {
                DuplicateGroup.Member(
                    url: URL(fileURLWithPath: $0.0.absolute_path),
                    fileID: $0.0.file_id,
                    sizeBytes: $0.1.size_bytes ?? 0,
                    width: $0.1.width,
                    height: $0.1.height,
                    isSuggestedKeeper: false
                )
            }
        }
        return scored.map { (path, file, _) in
            DuplicateGroup.Member(
                url: URL(fileURLWithPath: path.absolute_path),
                fileID: path.file_id,
                sizeBytes: file.size_bytes ?? 0,
                width: file.width,
                height: file.height,
                isSuggestedKeeper: path.id == best.0.id
            )
        }
    }

    // MARK: - Filename

    private func filenameGroups(urls: [URL]) -> [DuplicateGroup] {
        let groups = Dictionary(grouping: urls, by: { $0.lastPathComponent })
        return groups.values
            .filter { $0.count > 1 }
            .map { urls in
                // No suggestion per Q12
                let members = urls.map { url in
                    DuplicateGroup.Member(
                        url: url,
                        fileID: nil,
                        sizeBytes: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0,
                        width: nil,
                        height: nil,
                        isSuggestedKeeper: false
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

        // Pre-filter by resolution bucket (within ±10%) and dominant color hex equality.
        // Then brute-force cosine on the survivors.
        let printObs: [(PathRow, FileRow, VNFeaturePrintObservation)] = entries.compactMap { (p, f) in
            guard let data = f.feature_print,
                  let obs = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data) else {
                return nil
            }
            return (p, f, obs)
        }

        // Group candidates by bucket
        struct Bucket: Hashable {
            let kindBucket: Int
            let colorPrefix: String
        }
        func bucketFor(_ f: FileRow) -> Bucket {
            let area = (f.width ?? 0) * (f.height ?? 0)
            // Discretize area into ±10% bins via log
            let bin = area > 0 ? Int(log(Double(area)) / log(1.21)) : 0
            let prefix = String((f.dominant_color ?? "").prefix(4))
            return Bucket(kindBucket: bin, colorPrefix: prefix)
        }

        let bucketed = Dictionary(grouping: printObs, by: { bucketFor($0.1) })

        let threshold: Float = 0.45 // smaller distance = more similar

        var clusters: [[(PathRow, FileRow, VNFeaturePrintObservation)]] = []
        var visited = Set<String>()
        for (_, candidates) in bucketed where candidates.count >= 2 {
            for i in 0..<candidates.count {
                let key = candidates[i].0.id
                if visited.contains(key) { continue }
                var cluster: [(PathRow, FileRow, VNFeaturePrintObservation)] = [candidates[i]]
                visited.insert(key)
                for j in (i+1)..<candidates.count {
                    let otherKey = candidates[j].0.id
                    if visited.contains(otherKey) { continue }
                    var distance: Float = .infinity
                    do {
                        try candidates[i].2.computeDistance(&distance, to: candidates[j].2)
                    } catch {
                        continue
                    }
                    if distance < threshold {
                        cluster.append(candidates[j])
                        visited.insert(otherKey)
                    }
                }
                if cluster.count >= 2 {
                    clusters.append(cluster)
                }
            }
        }

        return clusters.map { cluster in
            let members = scoreVisualKeepers(items: cluster)
            return DuplicateGroup(id: UUID(), reason: .visual, members: members)
        }
    }

    /// Visual smart suggest: keep highest resolution, but only if gap is >10%.
    private func scoreVisualKeepers(items: [(PathRow, FileRow, VNFeaturePrintObservation)]) -> [DuplicateGroup.Member] {
        let pixels: [(idx: Int, px: Int)] = items.enumerated().map { (i, item) in
            (i, (item.1.width ?? 0) * (item.1.height ?? 0))
        }
        let maxPx = pixels.map { $0.px }.max() ?? 0
        let secondMax = pixels.map { $0.px }.sorted(by: >).dropFirst().first ?? 0
        let suggestKeeper = maxPx > 0 && Double(secondMax) / Double(maxPx) < 0.9
        let bestIdx = pixels.max(by: { $0.px < $1.px })?.idx

        return items.enumerated().map { (i, item) in
            let (path, file, _) = item
            return DuplicateGroup.Member(
                url: URL(fileURLWithPath: path.absolute_path),
                fileID: path.file_id,
                sizeBytes: file.size_bytes ?? 0,
                width: file.width,
                height: file.height,
                isSuggestedKeeper: suggestKeeper && i == bestIdx
            )
        }
    }
}
