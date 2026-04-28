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
    static let shared = Database()

    let dbQueue: DatabaseQueue?

    private init() {
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
            try Self.migrate(queue: queue)
            self.dbQueue = queue
        } catch {
            print("[Database] init failed: \(error)")
            self.dbQueue = nil
        }
    }

    // MARK: - Migrations

    private static func migrate(queue: DatabaseQueue) throws {
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

        try migrator.migrate(queue)
    }
}
