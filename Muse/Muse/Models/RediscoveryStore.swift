//
//  RediscoveryStore.swift
//  Muse
//
//  Rediscovery surface state — Pattern B. Resolves off-main under a request
//  token (the setActiveCollection stale-guard shape), so a superseded
//  activation can't land over a newer one.
//
//  `last_viewed_at` is device-local behavioural data: never exported to a
//  sidecar, never synced, never sent anywhere.
//

import Foundation
import GRDB

nonisolated enum RediscoverySurface: String, CaseIterable, Sendable {
    case rarelySeen, onThisDay, shuffle

    var title: String {
        switch self {
        case .rarelySeen: return String(localized: "Rarely Seen")
        case .onThisDay:  return String(localized: "On This Day")
        case .shuffle:    return String(localized: "Shuffle")
        }
    }
}

@MainActor final class RediscoveryStore: ObservableObject {
    static let shared = RediscoveryStore()
    private init() {}

    @Published private(set) var active: RediscoverySurface?
    @Published private(set) var files: [FileNode]?
    /// Plain, non-published: read by bookkeeping, never a render input.
    private(set) var paths: Set<String>?

    private var requestToken = 0
    /// Absorbs double-fires — a click and the viewer's own `.task(id:)` both
    /// report the same open.
    private var lastViewedDedupe: [String: Date] = [:]
    static let viewedDedupeWindow: TimeInterval = 5

    func activate(_ surface: RediscoverySurface, roots: [String]) {
        requestToken += 1
        let token = requestToken
        active = surface
        let seed = UInt64.random(in: 0...UInt64.max)
        Task { [weak self] in
            guard let self, let q = Database.shared.dbQueue else { return }
            let ids: [String] = (try? await q.read { db -> [String] in
                switch surface {
                case .rarelySeen:
                    return try RediscoveryQueries.rarelySeen(db: db)
                case .onThisDay:
                    let cal = Calendar(identifier: .gregorian)
                    let now = Date()
                    let md = String(format: "%02d-%02d",
                                    cal.component(.month, from: now),
                                    cal.component(.day, from: now))
                    return try RediscoveryQueries.onThisDay(
                        db: db, todayMD: md, currentYear: cal.component(.year, from: now))
                case .shuffle:
                    return try RediscoveryQueries.shuffle(db: db, seed: seed)
                }
            }) ?? []
            let resolved = await Self.resolveFileNodes(ids: ids, roots: roots)
            guard self.requestToken == token else { return }  // stale — superseded
            self.files = resolved
            self.paths = Set(resolved.map { $0.url.standardizedFileURL.path })
        }
    }

    func dismiss() {
        guard active != nil || files != nil else { return }
        requestToken += 1
        active = nil
        files = nil
        paths = nil
    }

    func reshuffle(roots: [String]) {
        guard active == .shuffle else { return }
        activate(.shuffle, roots: roots)
    }

    /// Drop a trashed/deleted path from the surface's members — the
    /// rediscovery mirror of `dropFromActiveCollection`, without which a
    /// burn-deleted tile reappears after the fade.
    func drop(path: String) {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        files?.removeAll { $0.url.standardizedFileURL.path == std }
        paths?.remove(std)
    }

    /// Records that the user actually looked at this file. Called from the
    /// VIEW layer only (AppState.selectedFile keeps no didSet).
    func markViewed(url: URL) {
        let std = url.standardizedFileURL.path
        let now = Date()
        if let last = lastViewedDedupe[std],
           now.timeIntervalSince(last) < Self.viewedDedupeWindow { return }
        lastViewedDedupe[std] = now
        Task.detached {
            guard let q = Database.shared.dbQueue else { return }
            try? await q.write { db in
                try db.execute(sql: """
                    UPDATE files SET last_viewed_at = ?
                    WHERE id = (SELECT file_id FROM paths
                                WHERE absolute_path = ? AND is_alive = 1 LIMIT 1)
                    """, arguments: [Int64(now.timeIntervalSince1970), std])
            }
        }
    }

    private static func resolveFileNodes(ids: [String], roots: [String]) async -> [FileNode] {
        guard let q = Database.shared.dbQueue, !ids.isEmpty else { return [] }
        let rows: [(id: String, path: String)] = (try? await q.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            return try Row.fetchAll(db, sql: """
                SELECT file_id, absolute_path FROM paths
                WHERE file_id IN (\(placeholders)) AND is_alive = 1
                """, arguments: StatementArguments(ids))
                .compactMap { row -> (String, String)? in
                    guard let id: String = row["file_id"],
                          let path: String = row["absolute_path"] else { return nil }
                    return (id, path)
                }
        }) ?? []

        let orderIndex = Dictionary(ids.enumerated().map { ($1, $0) },
                                    uniquingKeysWith: { a, _ in a })
        let underRoot = roots.isEmpty ? rows
            : rows.filter { CollectionStore.isUnderAnyRoot($0.path, roots: roots) }
        return underRoot
            .sorted {
                let a = orderIndex[$0.id] ?? .max, b = orderIndex[$1.id] ?? .max
                return a != b ? a < b : $0.path < $1.path
            }
            .map { FileNode(url: URL(fileURLWithPath: $0.path)) }
    }
}
