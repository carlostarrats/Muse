//
//  LutStore.swift
//  Muse
//
//  Imported 3D LUTs (v23). Pattern B, like every other new store: a MainActor
//  singleton with zero AppState integration.
//
//  Only LISTINGS are resident. The blobs live behind `LutRegistry`'s LRU on
//  the render path — a library of thirty 64³ cubes is ~90 MB, which has no
//  business sitting in the UI layer.
//
//  Import dedupes by content hash (INSERT OR IGNORE), so re-importing the same
//  `.cube` under a different filename is a no-op and the first name wins.
//  Delete never rewrites referencing stacks: an unresolvable LUT renders the
//  original, and re-importing the same file heals every photo at once.
//

import Foundation
import GRDB

@MainActor
final class LutStore: ObservableObject {
    static let shared = LutStore()

    struct Listing: Identifiable, Equatable {
        let id: String
        let name: String
        let size: Int
        let createdAt: Int64
    }

    @Published private(set) var luts: [Listing] = []

    /// Injectable so tests run against an isolated in-memory database rather
    /// than the user's real library.
    private let queueProvider: () -> DatabaseQueue?

    init(queue: DatabaseQueue? = nil) {
        if let queue {
            queueProvider = { queue }
        } else {
            queueProvider = { Database.shared.dbQueue }
        }
    }

    func reload() async {
        guard let queue = queueProvider() else { return }
        let rows = (try? await queue.read { db in
            try EditLutRow.fetchAll(db, sql: "SELECT * FROM edit_luts ORDER BY name COLLATE NOCASE")
        }) ?? []
        luts = rows.map { Listing(id: $0.id, name: $0.name, size: $0.size, createdAt: $0.created_at) }
    }

    /// Per-file failures keyed by FILENAME — the import panel names the file
    /// that failed, not a URL the user never typed.
    func importCubes(at urls: [URL]) async -> [String: Error] {
        guard let queue = queueProvider() else { return [:] }
        var failures: [String: Error] = [:]
        for url in urls {
            do {
                // Read and parse OFF the main actor. `LutStore` is `@MainActor`,
                // and a `.cube` is allowed up to `CubeLUTParser.maxFileBytes`
                // (64 MB) — a 128³ cube is 2,097,152 data lines, each split and
                // parsed into three Floats. Doing that inline froze the whole UI
                // for the duration of the import, on a file the user picked in a
                // panel that stays on screen while it happens.
                let parsed = try await Task.detached(priority: .userInitiated) {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    return try CubeLUTParser.parse(text)
                }.value
                let id = CubeLUT.hash(parsed.lut)
                let name = parsed.title ?? url.deletingPathExtension().lastPathComponent
                let blob = parsed.lut.canonicalData
                let size = parsed.lut.size
                let now = Int64(Date().timeIntervalSince1970)
                try await queue.write { db in
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO edit_luts (id, name, size, data, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """, arguments: [id, name, size, blob, now])
                }
                // The cube is already parsed and in hand — seed the render
                // cache rather than make the first render read it back off
                // disk, and make a previously-missing id resolvable at once.
                LutRegistry.preload(id: id, size: size, rgb: parsed.lut.data)
            } catch {
                failures[url.lastPathComponent] = error
            }
        }
        await reload()
        return failures
    }

    /// Display-only — the id is the content hash and cannot move.
    func rename(id: String, to name: String) async {
        guard let queue = queueProvider() else { return }
        try? await queue.write { db in
            try db.execute(sql: "UPDATE edit_luts SET name = ? WHERE id = ?", arguments: [name, id])
        }
        await reload()
    }

    /// Stacks referencing this LUT keep their blobs untouched; they render as
    /// originals until the same `.cube` is imported again.
    func delete(id: String) async {
        guard let queue = queueProvider() else { return }
        try? await queue.write { db in
            try db.execute(sql: "DELETE FROM edit_luts WHERE id = ?", arguments: [id])
        }
        LutRegistry.invalidate(id)
        await reload()
    }

    /// How many stored stacks mention this LUT — shown in the delete confirm so
    /// the count isn't a surprise afterwards. LIKE on a 64-hex id is
    /// unambiguous at that length.
    func referenceCount(id: String) async -> Int {
        guard let queue = queueProvider() else { return 0 }
        return (try? await queue.read { db -> Int in
            let pattern = "%\(id)%"
            let edits = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edits WHERE stack LIKE ?",
                                         arguments: [pattern]) ?? 0
            let versions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edit_versions WHERE stack LIKE ?",
                                            arguments: [pattern]) ?? 0
            let presets = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edit_presets WHERE stack LIKE ?",
                                           arguments: [pattern]) ?? 0
            return edits + versions + presets
        }) ?? 0
    }
}
