//
//  CollectionStore.swift
//  Muse
//
//  DB CRUD for AI-generated collections. Upserts replace membership
//  wholesale; hidden collections are excluded from fetchAll.
//

import Foundation
import GRDB

enum CollectionStore {
    struct Loaded {
        var collection: CollectionRow
        var memberIDs: [String]
        /// Members with an alive path — what the user actually has on disk.
        /// Cards, headers, and the row all display THIS, so deleting images
        /// or removing folders auto-shrinks (and at zero, hides) a collection.
        var aliveCount: Int
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

    /// Removes the collection and its memberships. Files are untouched.
    static func delete(queue: DatabaseQueue, id: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM collection_members WHERE collection_id = ?",
                           arguments: [id])
            try db.execute(sql: "DELETE FROM collections WHERE id = ?",
                           arguments: [id])
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
                return Loaded(collection: row, memberIDs: members, aliveCount: alive)
            }
            .filter { $0.aliveCount > 0 }                      // nothing on disk → hidden
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
