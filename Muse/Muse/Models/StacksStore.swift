//
//  StacksStore.swift
//  Muse
//
//  Pattern B store. `entries`/`expanded`/`generation` drive the grid's
//  collapse seam; `badges` is a PLAIN (non-@Published) var written inside the
//  memoized `visibleFiles` computation — publishing from there would loop.
//

import Foundation
import GRDB

@MainActor final class StacksStore: ObservableObject {
    static let shared = StacksStore()
    private init() {}

    /// Standardized path → its stack entry. Dissolved stacks are absent: a
    /// tombstoned stack is invisible to presentation.
    @Published private(set) var entries: [String: StackDisplay.Entry] = [:]
    @Published private(set) var expanded: Set<String> = []
    @Published private(set) var generation = 0
    /// NOT @Published — see the file header.
    var badges: [String: Int] = [:]

    private var reloadToken = 0

    func reload(for files: [FileNode]) async {
        reloadToken += 1
        let token = reloadToken
        guard let q = Database.shared.dbQueue, !files.isEmpty else {
            if !entries.isEmpty { entries = [:]; generation += 1 }
            return
        }
        let paths = files.map { $0.url.standardizedFileURL.path }
        let map = await Self.fileIDMap(paths: paths, q: q)
        guard reloadToken == token else { return }

        // Lazily auto-stack this folder's virgin files — no global launch pass.
        _ = await AutoStacker.run(fileIDs: Array(map.values))
        guard reloadToken == token else { return }

        let byFileID = Dictionary(map.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        let refs: [String: StackRef] = (try? await q.read { db in
            try StackStore.stacksFor(fileIDs: Array(byFileID.keys), db: db)
        }) ?? [:]
        guard reloadToken == token else { return }

        var newEntries: [String: StackDisplay.Entry] = [:]
        for (fileID, ref) in refs where !ref.dissolved {
            guard let path = byFileID[fileID] else { continue }
            newEntries[path] = StackDisplay.Entry(stackID: ref.stackID,
                                                  isPick: ref.pickFileID == fileID)
        }
        guard newEntries != entries else { return }
        entries = newEntries
        generation += 1
    }

    func toggleExpanded(_ stackID: String) {
        if expanded.contains(stackID) { expanded.remove(stackID) } else { expanded.insert(stackID) }
        generation += 1
    }

    func stackSelection(paths: [String]) async {
        guard let q = Database.shared.dbQueue else { return }
        let map = await Self.fileIDMap(paths: paths, q: q)
        // Preserve the caller's order so the first selected file is the pick.
        let fileIDs = paths.compactMap { map[URL(fileURLWithPath: $0).standardizedFileURL.path] }
        guard fileIDs.count >= 2 else { return }
        // `createStack` returns the new id; nothing here needs it, and the
        // explicit discard is what keeps the build warning-free.
        _ = try? await q.write { db in
            try StackStore.createStack(kind: "manual", memberIDs: fileIDs,
                                       pick: fileIDs.first, db: db)
        }
        await refreshEntries(paths: paths, q: q)
    }

    func unstack(_ stackID: String) async {
        guard let q = Database.shared.dbQueue else { return }
        try? await q.write { db in try StackStore.dissolve(stackID: stackID, db: db) }
        entries = entries.filter { $0.value.stackID != stackID }
        expanded.remove(stackID)
        generation += 1
    }

    func setPick(stackID: String, path: String) async {
        guard let q = Database.shared.dbQueue else { return }
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let fileID = await Self.fileIDMap(paths: [std], q: q)[std] else { return }
        try? await q.write { db in try StackStore.setPick(stackID: stackID, fileID: fileID, db: db) }
        for (p, entry) in entries where entry.stackID == stackID {
            entries[p] = StackDisplay.Entry(stackID: stackID, isPick: p == std)
        }
        generation += 1
    }

    func removeFromStack(path: String) async {
        guard let q = Database.shared.dbQueue else { return }
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let entry = entries[std],
              let fileID = await Self.fileIDMap(paths: [std], q: q)[std] else { return }
        try? await q.write { db in
            try StackStore.removeMember(stackID: entry.stackID, fileID: fileID, db: db)
        }
        entries.removeValue(forKey: std)
        // The removal may have dissolved the stack (below two members) — drop
        // any remaining entry for it rather than leaving a badge of one.
        let siblings = entries.filter { $0.value.stackID == entry.stackID }
        if siblings.count < 2 {
            for (p, _) in siblings { entries.removeValue(forKey: p) }
            expanded.remove(entry.stackID)
        }
        generation += 1
    }

    private func refreshEntries(paths: [String], q: DatabaseQueue) async {
        let map = await Self.fileIDMap(paths: paths, q: q)
        let byFileID = Dictionary(map.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        let refs: [String: StackRef] = (try? await q.read { db in
            try StackStore.stacksFor(fileIDs: Array(byFileID.keys), db: db)
        }) ?? [:]
        for (fileID, ref) in refs {
            guard let path = byFileID[fileID] else { continue }
            if ref.dissolved {
                entries.removeValue(forKey: path)
            } else {
                entries[path] = StackDisplay.Entry(stackID: ref.stackID,
                                                   isPick: ref.pickFileID == fileID)
            }
        }
        generation += 1
    }

    /// Standardized path → file_id, for alive paths only.
    private static func fileIDMap(paths: [String], q: DatabaseQueue) async -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        let standardized = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        return (try? await q.read { db -> [String: String] in
            var out: [String: String] = [:]
            var index = 0
            while index < standardized.count {
                let end = min(index + StackStore.idChunk, standardized.count)
                let chunk = Array(standardized[index..<end])
                index = end
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT file_id, absolute_path FROM paths
                    WHERE absolute_path IN (\(placeholders)) AND is_alive = 1
                    """, arguments: StatementArguments(chunk))
                for row in rows {
                    guard let fid: String = row["file_id"],
                          let path: String = row["absolute_path"] else { continue }
                    out[path] = fid
                }
            }
            return out
        }) ?? [:]
    }
}
