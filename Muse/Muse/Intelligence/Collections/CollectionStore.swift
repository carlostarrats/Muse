//
//  CollectionStore.swift
//  Muse
//
//  DB CRUD for AI-generated collections. Upserts replace membership
//  wholesale; hidden collections are excluded from fetchAll.
//

import Foundation
import GRDB

/// Default naming for hand-made collections: "Collection 1", "Collection 2", …
/// The next number is one past the highest existing "Collection N" (across all
/// collections, so numbers never collide), with gaps ignored.
enum ManualCollectionName {
    static let prefix = "Collection "

    static func next(existing names: [String]) -> String {
        let maxN = names.compactMap(number(in:)).max() ?? 0
        return "\(prefix)\(maxN + 1)"
    }

    /// The N in "Collection N", or nil if the name isn't of that exact form.
    static func number(in name: String) -> Int? {
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = name.dropFirst(prefix.count)
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        return Int(suffix)
    }
}

enum CollectionStore {
    struct Loaded {
        var collection: CollectionRow
        var memberIDs: [String]
        /// Members with an alive path — what the user actually has on disk.
        /// Cards, headers, and the row all display THIS, so deleting images
        /// or removing folders auto-shrinks (and at zero, hides) a collection.
        var aliveCount: Int
        /// User-chosen cover file id; nil = auto (first alive member).
        var coverFileID: String?
    }

    static func upsert(queue: DatabaseQueue, id: String, name: String,
                       memberIDs: [String], modelVersion: String) async throws {
        let now = Int64(Date().timeIntervalSince1970)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at)
                VALUES (?, ?, 0, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name,
                    model_version = excluded.model_version, updated_at = excluded.updated_at
                """, arguments: [id, name, modelVersion, now, now])
            // Only auto members are rebuilt; manual adds survive reclustering.
            try db.execute(sql: """
                DELETE FROM collection_members WHERE collection_id = ? AND added_by = 'auto'
                """, arguments: [id])
            let excluded = try Set(String.fetchAll(db, sql:
                "SELECT file_id FROM collection_exclusions WHERE collection_id = ?",
                arguments: [id]))
            for fid in memberIDs where !excluded.contains(fid) {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO collection_members (collection_id, file_id, added_by)
                    VALUES (?, ?, 'auto')
                    """, arguments: [id, fid])
            }
        }
    }

    /// Manually add a file to a collection. Clears any standing exclusion.
    static func addFile(queue: DatabaseQueue, fileID: String, collectionID: String) async throws {
        try await queue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO collection_members (collection_id, file_id, added_by)
                VALUES (?, ?, 'manual')
                """, arguments: [collectionID, fileID])
            try db.execute(sql: "DELETE FROM collection_exclusions WHERE collection_id = ? AND file_id = ?",
                           arguments: [collectionID, fileID])
        }
    }

    /// Resolve standardized absolute paths to their (alive) file_ids.
    static func fileIDs(queue: DatabaseQueue, paths: [String]) async throws -> [String] {
        guard !paths.isEmpty else { return [] }
        return try await queue.read { db in
            let placeholders = paths.map { _ in "?" }.joined(separator: ",")
            let rows = try PathRow.fetchAll(
                db,
                sql: "SELECT * FROM paths WHERE absolute_path IN (\(placeholders)) AND is_alive = 1",
                arguments: StatementArguments(paths))
            return rows.compactMap { $0.file_id }
        }
    }

    /// Manually remove a file from a collection. Records an exclusion so
    /// future auto rebuilds cannot re-add it.
    static func removeFile(queue: DatabaseQueue, fileID: String, collectionID: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM collection_members WHERE collection_id = ? AND file_id = ?",
                           arguments: [collectionID, fileID])
            try db.execute(sql: """
                INSERT OR IGNORE INTO collection_exclusions (collection_id, file_id) VALUES (?, ?)
                """, arguments: [collectionID, fileID])
        }
    }

    /// Visible collections containing a given file.
    static func collections(queue: DatabaseQueue, forFileID fileID: String) async throws -> [CollectionRow] {
        try await queue.read { db in
            try CollectionRow.fetchAll(db, sql: """
                SELECT c.* FROM collections c
                JOIN collection_members m ON m.collection_id = c.id
                WHERE m.file_id = ? AND c.is_hidden = 0
                """, arguments: [fileID])
        }
    }

    /// Create a brand-new manual collection containing one file.
    static func createManual(queue: DatabaseQueue, name: String, fileID: String) async throws -> String {
        let id = UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at)
                VALUES (?, ?, 0, 'manual', ?, ?)
                """, arguments: [id, name, now, now])
            try db.execute(sql: """
                INSERT INTO collection_members (collection_id, file_id, added_by) VALUES (?, ?, 'manual')
                """, arguments: [id, fileID])
        }
        return id
    }

    /// Collections that must never be deleted as stale by the engine:
    /// manual model_version OR any manual members.
    static func protectedCollectionIDs(queue: DatabaseQueue) async throws -> Set<String> {
        try await queue.read { db in
            var ids = try Set(String.fetchAll(db, sql:
                "SELECT id FROM collections WHERE model_version = 'manual'"))
            ids.formUnion(try String.fetchAll(db, sql:
                "SELECT DISTINCT collection_id FROM collection_members WHERE added_by = 'manual'"))
            return ids
        }
    }

    static func rename(queue: DatabaseQueue, id: String, name: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "UPDATE collections SET name = ? WHERE id = ?",
                           arguments: [name, id])
        }
    }

    /// Create an empty, hand-made collection auto-named "Collection N".
    /// Marked model_version = 'manual' so the auto-organizer never reclusters
    /// or prunes it (it's protected + shown even while empty). Returns its id.
    /// Name choice + insert happen in one write so concurrent adds can't collide.
    @discardableResult
    static func createManual(queue: DatabaseQueue) async throws -> String {
        let id = UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970)
        try await queue.write { db in
            let names = try String.fetchAll(db, sql: "SELECT name FROM collections")
            let name = ManualCollectionName.next(existing: names)
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at)
                VALUES (?, ?, 0, 'manual', ?, ?)
                """, arguments: [id, name, now, now])
        }
        return id
    }

    // NOTE: there is intentionally no hard-delete. Collections are auto-
    // generated, so a row-delete silently regenerates on the next analyze.
    // Deletion goes through setHidden(true) (the durable "don't rebuild"
    // tombstone) — see ActiveCollectionHeader/CollectionCard.deleteCollection.

    /// Set (or replace) a collection's chosen cover image. One per collection.
    static func setCover(queue: DatabaseQueue, id: String, fileID: String) async throws {
        let now = Int64(Date().timeIntervalSince1970)
        try await queue.write { db in
            try db.execute(sql: "UPDATE collections SET cover_file_id = ?, updated_at = ? WHERE id = ?",
                           arguments: [fileID, now, id])
        }
    }

    /// Resolve an alive file's absolute path to its file id (nil if not indexed
    /// / not alive). Mirrors the lookup TagStore uses.
    static func fileID(queue: DatabaseQueue, path: String) async throws -> String? {
        try await queue.read { db in
            try PathRow
                .filter(PathRow.Columns.absolute_path == path)
                .filter(PathRow.Columns.is_alive == 1)
                .fetchOne(db)?
                .file_id
        }
    }

    /// The chosen cover's alive absolute path — but only if it's still an alive
    /// member of the collection. Returns nil otherwise so callers fall back to
    /// the auto cover (first alive member).
    static func coverPath(queue: DatabaseQueue, collectionID: String,
                          coverFileID: String) async throws -> String? {
        try await queue.read { db in
            try String.fetchOne(db, sql: """
                SELECT p.absolute_path FROM paths p
                JOIN collection_members m ON m.file_id = p.file_id
                WHERE p.is_alive = 1 AND p.file_id = ? AND m.collection_id = ?
                LIMIT 1
                """, arguments: [coverFileID, collectionID])
        }
    }

    static func setHidden(queue: DatabaseQueue, id: String, hidden: Bool) async throws {
        try await queue.write { db in
            try db.execute(sql: "UPDATE collections SET is_hidden = ? WHERE id = ?",
                           arguments: [hidden ? 1 : 0, id])
        }
    }

    static func fetchAll(queue: DatabaseQueue) async throws -> [Loaded] {
        try await queue.read { db in
            let rows = try CollectionRow
                .filter(Column("is_hidden") == 0)
                .fetchAll(db)
            return try rows.map { row in
                let members = try String.fetchAll(db, sql:
                    "SELECT file_id FROM collection_members WHERE collection_id = ?",
                    arguments: [row.id])
                let alive = try Int.fetchOne(db, sql: """
                    SELECT COUNT(DISTINCT p.file_id) FROM paths p
                    JOIN collection_members m ON m.file_id = p.file_id
                    WHERE m.collection_id = ? AND p.is_alive = 1
                    """, arguments: [row.id]) ?? 0
                return Loaded(collection: row, memberIDs: members, aliveCount: alive,
                              coverFileID: row.cover_file_id)
            }
            // Auto collections with nothing on disk are hidden; hand-made
            // ('manual') collections stay visible even while empty, so a just-
            // created one shows up and can be populated.
            .filter { $0.aliveCount > 0 || $0.collection.model_version == "manual" }
            .sorted { $0.aliveCount > $1.aliveCount }          // biggest first
        }
    }

    /// Alive absolute paths for a collection's members (for mosaics and
    /// grid filtering). Optional limit for cover thumbnails.
    static func alivePaths(queue: DatabaseQueue, collectionID: String,
                           limit: Int? = nil) async throws -> [String] {
        try await queue.read { db in
            var sql = """
                SELECT absolute_path FROM paths
                WHERE is_alive = 1 AND file_id IN
                    (SELECT file_id FROM collection_members WHERE collection_id = ?)
                """
            if let limit { sql += " LIMIT \(limit)" }
            return try String.fetchAll(db, sql: sql, arguments: [collectionID])
        }
    }

    /// Old state for identity matching: id -> member set
    static func currentMembership(queue: DatabaseQueue) async throws -> [String: Set<String>] {
        try await queue.read { db in
            var out: [String: Set<String>] = [:]
            let rows = try Row.fetchAll(db, sql:
                "SELECT collection_id, file_id FROM collection_members")
            for r in rows {
                out[r["collection_id"], default: []].insert(r["file_id"])
            }
            return out
        }
    }
}
