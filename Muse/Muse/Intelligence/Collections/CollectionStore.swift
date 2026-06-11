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
            try db.execute(sql: "DELETE FROM collection_members WHERE collection_id = ?",
                           arguments: [id])
            for fid in memberIDs {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO collection_members (collection_id, file_id)
                    VALUES (?, ?)
                    """, arguments: [id, fid])
            }
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
                return Loaded(collection: row, memberIDs: members)
            }
            .sorted { $0.memberIDs.count > $1.memberIDs.count }   // biggest first
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
