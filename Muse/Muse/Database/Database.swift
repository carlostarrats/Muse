//
//  Database.swift
//  Muse
//
//  GRDB-backed SQLite database. Schema follows the rewrite plan §4:
//  files, paths, tags, roots (sidebar persistence), smart_searches,
//  duplicate_groups + duplicate_members, FTS5 virtual table keyed by
//  files.id, partial unique index on alive paths.
//
//  The database lives at:
//  ~/Library/Application Support/Muse/muse.sqlite
//  (separate from the legacy file the old import-based app used; that
//  file is left untouched on disk per Q22.)
//

import Foundation
import GRDB

@MainActor
final class Database {
    // The singleton + queue are an immutable, Sendable GRDB handle with a
    // pure initializer — safe to read from any context (background actors:
    // Indexer, AnalyzePipeline, etc.). Keep @MainActor on the type for any
    // future main-actor members, but expose these nonisolated.
    nonisolated static let shared = Database()

    nonisolated let dbQueue: DatabaseQueue?

    nonisolated private init() {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            self.dbQueue = nil
            return
        }
        let dir = appSupport.appendingPathComponent("Muse", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("muse.sqlite")

        do {
            let queue = try DatabaseQueue(path: dbURL.path)
            try Self.makeMigrator().migrate(queue)
            self.dbQueue = queue
        } catch {
            print("[Database] init failed: \(error)")
            self.dbQueue = nil
        }
    }

    // MARK: - Migrations

    nonisolated static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_schema") { db in
            try db.execute(sql: """
                CREATE TABLE files (
                    id TEXT PRIMARY KEY NOT NULL,
                    content_hash TEXT UNIQUE,
                    kind TEXT NOT NULL,
                    size_bytes INTEGER,
                    width INTEGER,
                    height INTEGER,
                    duration_seconds REAL,
                    created_at INTEGER,
                    modified_at INTEGER,
                    last_seen_at INTEGER NOT NULL,
                    caption TEXT,
                    dominant_color TEXT,
                    feature_print BLOB
                );
            """)

            try db.execute(sql: """
                CREATE TABLE paths (
                    id TEXT PRIMARY KEY NOT NULL,
                    file_id TEXT,
                    absolute_path TEXT NOT NULL,
                    bookmark_data BLOB,
                    is_alive INTEGER NOT NULL DEFAULT 1,
                    FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE SET NULL
                );
            """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX paths_alive_unique
                    ON paths(absolute_path) WHERE is_alive = 1;
            """)
            try db.execute(sql: """
                CREATE INDEX paths_file_id_idx ON paths(file_id);
            """)

            try db.execute(sql: """
                CREATE TABLE tags (
                    id TEXT PRIMARY KEY NOT NULL,
                    file_id TEXT NOT NULL,
                    label TEXT NOT NULL,
                    source TEXT NOT NULL,
                    confidence REAL,
                    FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE,
                    UNIQUE (file_id, label)
                );
            """)

            try db.execute(sql: """
                CREATE TABLE roots (
                    id TEXT PRIMARY KEY NOT NULL,
                    bookmark_data BLOB NOT NULL,
                    display_name TEXT NOT NULL,
                    added_at INTEGER NOT NULL,
                    is_starred INTEGER NOT NULL DEFAULT 0
                );
            """)

            try db.execute(sql: """
                CREATE TABLE smart_searches (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    query_json TEXT NOT NULL
                );
            """)

            try db.execute(sql: """
                CREATE TABLE starred_folders (
                    id TEXT PRIMARY KEY NOT NULL,
                    absolute_path TEXT NOT NULL UNIQUE,
                    bookmark_data BLOB,
                    display_name TEXT NOT NULL,
                    added_at INTEGER NOT NULL
                );
            """)

            try db.execute(sql: """
                CREATE TABLE duplicate_groups (
                    id TEXT PRIMARY KEY NOT NULL,
                    reason TEXT NOT NULL,
                    created_at INTEGER NOT NULL
                );
            """)
            try db.execute(sql: """
                CREATE TABLE duplicate_members (
                    group_id TEXT NOT NULL,
                    file_id TEXT NOT NULL,
                    is_suggested_keeper INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (group_id, file_id),
                    FOREIGN KEY (group_id) REFERENCES duplicate_groups(id) ON DELETE CASCADE,
                    FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
                );
            """)

            // FTS5 keyed by immutable files.id (not content_hash, which mutates on edit-in-place)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE files_fts USING fts5(
                    file_id UNINDEXED,
                    basename,
                    ocr_text,
                    caption,
                    tokenize = 'porter unicode61 remove_diacritics 1'
                );
            """)
        }

        migrator.registerMigration("v2_intelligence") { db in
            try db.create(table: "embeddings") { t in
                t.column("file_id", .text).primaryKey()
                    .references("files", onDelete: .cascade)
                t.column("vector", .blob).notNull()       // Float32 array, little-endian
                t.column("model_version", .text).notNull()
                t.column("updated_at", .integer).notNull()
            }
            try db.create(table: "collections") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("is_hidden", .integer).notNull().defaults(to: 0)
                t.column("model_version", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
            }
            try db.create(table: "collection_members") { t in
                t.column("collection_id", .text).notNull()
                    .references("collections", onDelete: .cascade)
                t.column("file_id", .text).notNull()
                    .references("files", onDelete: .cascade)
                t.primaryKey(["collection_id", "file_id"])
            }
            try db.create(index: "collection_members_file_id_idx",
                          on: "collection_members", columns: ["file_id"])
            try db.alter(table: "tags") { t in
                t.add(column: "model_version", .text)     // nil for manual/legacy
            }
            try db.alter(table: "files") { t in
                t.add(column: "palette", .text)           // JSON array of hex strings, ≤6
            }
        }

        migrator.registerMigration("v3_membership") { db in
            try db.alter(table: "collection_members") { t in
                t.add(column: "added_by", .text).notNull().defaults(to: "auto")  // "auto" | "manual"
            }
            try db.create(table: "collection_exclusions") { t in
                t.column("collection_id", .text).notNull()
                    .references("collections", onDelete: .cascade)
                t.column("file_id", .text).notNull()
                    .references("files", onDelete: .cascade)
                t.primaryKey(["collection_id", "file_id"])
            }
        }

        migrator.registerMigration("v4_auto_analyze") { db in
            // Incremental auto-analysis: a file is (re)analyzed only when
            // analyzed_hash is missing or no longer matches content_hash.
            try db.alter(table: "files") { t in
                t.add(column: "analyzed_hash", .text)
            }
        }

        migrator.registerMigration("v5_intent") { db in
            // Screenshot intent typing: a per-file bucket + the classifier
            // version that produced it. Both nullable; populated lazily by the
            // analyze pipeline and a one-time backfill.
            try db.alter(table: "files") { t in
                t.add(column: "intent", .text)
                t.add(column: "intent_model_version", .text)
            }
        }

        migrator.registerMigration("v6_collection_cover") { db in
            // Optional user-chosen cover image per collection. Nil = auto (the
            // first alive member). A manual choice survives reclustering.
            try db.alter(table: "collections") { t in
                t.add(column: "cover_file_id", .text)
            }
        }

        migrator.registerMigration("v7_tag_parent_dir") { db in
            // Tags become per-file-LOCATION. A tag's identity changes from
            // file_id (content) to (file_id, parent_dir) — the same content in
            // a different folder is a different image with its own tags. Rebuild
            // the table (SQLite can't drop an inline UNIQUE) and FAN OUT each
            // existing tag across the distinct alive parent folders of its
            // file_id, so everything currently visible is preserved and only
            // then diverges. A tag whose file has no alive path keeps a NULL
            // parent_dir (harmless: it never surfaces; housekeeping prunes it).
            try db.execute(sql: """
                CREATE TABLE tags_new (
                    id TEXT PRIMARY KEY NOT NULL,
                    file_id TEXT NOT NULL,
                    parent_dir TEXT,
                    label TEXT NOT NULL,
                    source TEXT NOT NULL,
                    confidence REAL,
                    model_version TEXT,
                    FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE,
                    UNIQUE (file_id, parent_dir, label)
                );
            """)

            // Build file_id -> {parent_dir} from alive paths once.
            var dirsByFile: [String: Set<String>] = [:]
            let pathRows = try Row.fetchAll(db, sql: """
                SELECT file_id, absolute_path FROM paths
                WHERE is_alive = 1 AND file_id IS NOT NULL
            """)
            for row in pathRows {
                guard let fid: String = row["file_id"],
                      let path: String = row["absolute_path"] else { continue }
                dirsByFile[fid, default: []].insert(TagScope.parentDir(ofPath: path))
            }

            // Fan each existing tag out across its file's alive parent folders.
            // The FIRST scope reuses the original tag id (no churn for the common
            // single-folder case); extra duplicate-folder copies get fresh ids.
            let tagRows = try Row.fetchAll(db, sql:
                "SELECT id, file_id, label, source, confidence, model_version FROM tags")
            for row in tagRows {
                guard let originalID: String = row["id"],
                      let fid: String = row["file_id"],
                      let label: String = row["label"],
                      let source: String = row["source"] else { continue }
                let confidence: Double? = row["confidence"]
                let modelVersion: String? = row["model_version"]
                let dirs = dirsByFile[fid].map(Array.init(_:)) ?? []
                // No alive path -> single NULL-scoped row (preserve, don't surface).
                let scopes: [String?] = dirs.isEmpty ? [nil] : dirs.map { $0 }
                for (i, dir) in scopes.enumerated() {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO tags_new
                            (id, file_id, parent_dir, label, source, confidence, model_version)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [i == 0 ? originalID : UUID().uuidString,
                                     fid, dir, label, source, confidence, modelVersion])
                }
            }

            try db.execute(sql: "DROP TABLE tags;")
            try db.execute(sql: "ALTER TABLE tags_new RENAME TO tags;")
            // No separate file_id index needed: UNIQUE(file_id, parent_dir,
            // label) already creates a file_id-leading index that serves
            // `WHERE file_id = ?` / `IN (...)` lookups.
        }

        return migrator
    }
}
