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
            // Enforce foreign keys explicitly. GRDB enables them by default, but
            // Housekeeping's prune deletes only `files`/`paths`/`tags`/`files_fts`
            // and relies on ON DELETE CASCADE to clear embeddings,
            // collection_members, and duplicate_members — so make that load-bearing
            // dependency explicit rather than implicit in a framework default.
            var config = Configuration()
            config.foreignKeysEnabled = true
            let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
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

        migrator.registerMigration("v8_collection_sort_order") { db in
            // Sidebar-only manual ordering for collections. Independent of the
            // Collections PAGE sort. New rows append (max+1) via CollectionStore.
            try db.alter(table: "collections") { t in
                t.add(column: "sort_order", .integer).notNull().defaults(to: 0)
            }
            try Database.backfillCollectionSortOrder(db)
        }

        migrator.registerMigration("v9_fts_basename_backfill") { db in
            // Historically only ANALYZED IMAGES got a files_fts row (written by
            // analyzeOne), so library-wide search could never find a PDF/video/
            // archive by name. Indexer now seeds a basename-only row for every
            // new file; this backfills the rows for everything already indexed.
            try Database.backfillBasenameFTS(db)
        }

        migrator.registerMigration("v10_collection_appearance") { db in
            // Optional per-collection sidebar appearance: an SF Symbol name and
            // a canonical color token ("red", never hex — tokens resolve to
            // system colors that adapt to light/dark). Both nil = the default
            // look (`CollectionAppearance.defaultIcon`, primary /
            // accent-when-selected) — named by the constant rather than spelled
            // out, so this migration comment can't drift when the glyph changes.
            try db.alter(table: "collections") { t in
                t.add(column: "icon", .text)
                t.add(column: "color", .text)
            }
        }

        migrator.registerMigration("v11_file_note") { db in
            // A user-authored free-text note, per file-LOCATION (file_id, parent_dir)
            // like tags — never a files/content-hash column (files.content_hash is
            // UNIQUE, so one file in two folders could carry two different notes).
            // Absence of a row = "no note"; an emptied note deletes its row.
            try db.create(table: "notes") { t in
                t.column("file_id", .text).notNull()
                t.column("parent_dir", .text).notNull()
                t.column("body", .text).notNull()
                t.column("updated_at", .integer).notNull()
                t.primaryKey(["file_id", "parent_dir"])
                t.foreignKey(["file_id"], references: "files", columns: ["id"], onDelete: .cascade)
            }
        }

        migrator.registerMigration("v12_smart_collections") { db in
            // A smart collection stores ONLY its rule set (JSON) and holds no
            // collection_members — its membership is resolved live from the DB
            // every time it's shown. smart_rules IS NOT NULL ⇒ smart collection;
            // existing manual/auto collections keep smart_rules = NULL, untouched.
            try db.alter(table: "collections") { t in
                t.add(column: "smart_rules", .text)
            }
        }

        migrator.registerMigration("v13_coordinates") { db in
            // GPS lives in the file's own bytes — content-keyed like palette/caption/
            // dominant_color/feature_print, deliberately NOT the tags/notes
            // per-location grain (two byte-identical copies in different folders
            // have identical coordinates by definition; edit-in-place already
            // splits the row).
            try db.alter(table: "files") { t in
                t.add(column: "lat", .double)
                t.add(column: "lon", .double)
                // The content_hash we last read GPS from. Storing the hash (not a
                // bare bool) means an edit-in-place re-reads new bytes for new GPS,
                // mirroring analyzed_hash — and avoids the analyzed_hash-NULL
                // retry-loop bug shape (2026-07-28): without an attempted-marker,
                // every GPS-less file would be re-opened on every launch forever.
                t.add(column: "coords_scanned_hash", .text)
            }
            // Partial index — a library with no geotagged photos costs nothing.
            try db.execute(sql: """
                CREATE INDEX files_coords_idx ON files(lat, lon) WHERE lat IS NOT NULL
                """)
        }

        migrator.registerMigration("v14_photo_meta") { db in
            // EXIF gets its own table rather than columns on `files` — every
            // existing fetch path does `SELECT *` on files, and eleven more
            // columns would ride along on all of them for no benefit.
            try db.create(table: "photo_meta") { t in
                t.column("file_id", .text).primaryKey()
                    .references("files", onDelete: .cascade)
                t.column("exif_scanned_hash", .text)
                t.column("capture_date", .integer)   // unix seconds (DateTimeOriginal, local-time)
                t.column("capture_md", .text)        // "MM-DD" — materialized on-this-day key
                t.column("camera_make", .text)
                t.column("camera_model", .text)
                t.column("lens", .text)
                t.column("iso", .integer)
                t.column("f_number", .double)
                t.column("exposure_seconds", .double)
                t.column("focal_length", .double)    // mm
                t.column("focal_length_35mm", .integer)
                t.column("flash_fired", .boolean)    // EXIF Flash bit 0; nil = unknown
            }
            // capture_md is MATERIALIZED, not computed with strftime at query
            // time: a strftime WHERE clause can't use an index. The
            // "query time touches only precomputed data" rule at schema level.
            try db.create(index: "photo_meta_capture_idx", on: "photo_meta", columns: ["capture_date"])
            try db.create(index: "photo_meta_md_idx", on: "photo_meta", columns: ["capture_md"])
            try db.create(index: "photo_meta_camera_idx", on: "photo_meta", columns: ["camera_make", "camera_model"])
            try db.create(index: "photo_meta_lens_idx", on: "photo_meta", columns: ["lens"])
            try db.create(index: "photo_meta_iso_idx", on: "photo_meta", columns: ["iso"])
            try db.create(index: "photo_meta_f_idx", on: "photo_meta", columns: ["f_number"])
            try db.create(index: "photo_meta_focal_idx", on: "photo_meta", columns: ["focal_length"])
        }

        migrator.registerMigration("v15_places") { db in
            // A row with NULL place fields means "geocoded, nothing within
            // range" — the row itself is the attempted-marker, so an ocean
            // photo isn't re-geocoded on every launch. country holds the ISO
            // 3166-1 alpha-2 code; display names resolve at render time.
            try db.create(table: "places") { t in
                t.column("file_id", .text).primaryKey()
                    .references("files", onDelete: .cascade)
                t.column("geocoded_hash", .text).notNull()
                t.column("dataset_version", .integer).notNull()
                t.column("city", .text)
                t.column("admin", .text)
                t.column("country", .text)
                t.column("place_key", .text)
            }
            try db.create(index: "places_key_idx", on: "places", columns: ["place_key"])
        }

        migrator.registerMigration("v16_rediscovery") { db in
            // Device-local behavioral data: never exported to sidecars, never
            // synced, never sent anywhere. No index — rediscovery queries run
            // once per surface activation, never per keystroke.
            try db.alter(table: "files") { t in
                t.add(column: "last_viewed_at", .integer)
            }
        }

        migrator.registerMigration("v17_stacks") { db in
            // Stacks are presentation-only, content-keyed sets of file ids.
            // `dissolved` is a permanent tombstone (the collection setHidden
            // pattern): unstacking keeps the row + members so the auto-stacker
            // never re-forms it.
            try db.create(table: "stacks") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull()          // "auto" | "manual"
                t.column("dissolved", .boolean).notNull().defaults(to: false)
                t.column("pick_file_id", .text)
                t.column("created_at", .integer).notNull()
            }
            try db.create(table: "stack_members") { t in
                t.column("stack_id", .text).notNull()
                    .references("stacks", onDelete: .cascade)
                t.column("file_id", .text).notNull()
                    .references("files", onDelete: .cascade)
                t.primaryKey(["stack_id", "file_id"])
            }
            try db.create(index: "stack_members_file_idx", on: "stack_members", columns: ["file_id"])
        }

        migrator.registerMigration("v18_clip_embeddings") { db in
            // CLIP's 512-d joint embedding, fp16, content-keyed (same grain as
            // palette/feature_print/photo_meta — NOT the (file_id, parent_dir)
            // grain tags use). A NULL vector is a legitimate attempted-marker:
            // the file was reached and couldn't be embedded, so the backfill
            // must not retry it every launch.
            try db.create(table: "clip_embeddings") { t in
                t.column("file_id", .text).primaryKey()
                    .references("files", onDelete: .cascade)
                t.column("embedded_hash", .text).notNull()
                t.column("model_generation", .integer).notNull()
                t.column("vector", .blob)
            }
        }

        migrator.registerMigration("v19_photo_traits") { db in
            // One shared table for faces + pets + sharpness: all raster-derived
            // scalars from a single decode. traits_version covers future trait
            // additions without a new marker column or a parallel table.
            // A missing row means UNSCANNED — which is why `faces:0` matches
            // only files that actually have a row.
            try db.create(table: "photo_traits") { t in
                t.column("file_id", .text).primaryKey()
                    .references("files", onDelete: .cascade)
                t.column("traits_scanned_hash", .text).notNull()
                t.column("traits_version", .integer).notNull()
                t.column("face_count", .integer)
                t.column("largest_face_frac", .double)
                t.column("face_quality", .double)
                t.column("pet_count", .integer)
                t.column("sharpness", .double)
            }
            try db.create(index: "photo_traits_faces_idx", on: "photo_traits", columns: ["face_count"])
            try db.create(index: "photo_traits_pets_idx", on: "photo_traits", columns: ["pet_count"])
        }

        migrator.registerMigration("v20_edits") { db in
            // The CURRENT edit stack, one row per (file, folder). The grain is
            // (file_id, parent_dir) — the tags/notes grain — deliberately NOT a
            // column on `files`: content_hash is UNIQUE there, so two folders'
            // copies of the same bytes would be forced to share one stack.
            //
            // A NEUTRAL stack deletes the row. "No edit" is the absence of a
            // row, never a stored no-op (the NoteStore.write blank-deletes
            // rule) — which is also what reverts the thumbnail cache key to
            // its nil-stack variant.
            try db.create(table: "edits") { t in
                t.column("file_id", .text).notNull()
                    .references("files", onDelete: .cascade)
                t.column("parent_dir", .text).notNull()
                t.column("stack", .text).notNull()          // canonical JSON
                t.column("stack_hash", .text).notNull()
                // Denormalized so a consumer can refuse to render a stack from
                // a newer renderer without decoding the blob first.
                t.column("process_version", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.primaryKey(["file_id", "parent_dir"])
            }
            // Versions and snapshots share one table, differing only in which
            // surface shows them (the version switcher vs the compare picker).
            try db.create(table: "edit_versions") { t in
                t.column("id", .text).primaryKey()
                t.column("file_id", .text).notNull()
                    .references("files", onDelete: .cascade)
                t.column("parent_dir", .text).notNull()
                t.column("kind", .text).notNull()           // "version" | "snapshot"
                t.column("name", .text).notNull()
                t.column("stack", .text).notNull()
                t.column("created_at", .integer).notNull()
            }
            try db.create(index: "edit_versions_scope_idx", on: "edit_versions",
                          columns: ["file_id", "parent_dir"])
        }

        migrator.registerMigration("v21_edit_presets") { db in
            // Library-global looks. No UNIQUE on name — two presets called
            // "Warm" is the user's business, not a constraint violation.
            try db.create(table: "edit_presets") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                // Stored MINUS the geometry group: a preset carrying a crop
                // ambushes every photo it's applied to.
                t.column("stack", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
            }
        }

        return migrator
    }

    /// Insert a basename-only files_fts row for every file that has none,
    /// using its first alive path's last component. Idempotent (guarded by
    /// NOT EXISTS); files with no alive path are skipped (housekeeping owns
    /// their lifecycle). `nonisolated` to match `makeMigrator()`.
    nonisolated static func backfillBasenameFTS(_ db: GRDB.Database) throws {
        // files_fts.file_id is UNINDEXED, so a correlated NOT EXISTS would be
        // a full FTS scan PER files row — O(n²) inside the migrator, i.e. a
        // launch hang on a large library. Fetch the covered ids once instead.
        let covered = Set(try String.fetchAll(db, sql: "SELECT file_id FROM files_fts"))
        let rows = try Row.fetchAll(db, sql: """
            SELECT f.id AS fid,
                   (SELECT p.absolute_path FROM paths p
                    WHERE p.file_id = f.id AND p.is_alive = 1 LIMIT 1) AS path
            FROM files f
            """)
        for row in rows {
            guard let fid: String = row["fid"], !covered.contains(fid),
                  let path: String = row["path"] else { continue }
            try db.execute(sql: """
                INSERT INTO files_fts(file_id, basename, ocr_text, caption)
                VALUES (?, ?, '', '')
                """, arguments: [fid, (path as NSString).lastPathComponent])
        }
    }

    /// Assign collections.sort_order = 0,1,2,… ordered by created_at then name,
    /// so an existing library gets a stable manual baseline. Idempotent.
    /// `nonisolated` to match `makeMigrator()` (callable from the migration
    /// closure + tests on a possibly @MainActor `Database`).
    nonisolated static func backfillCollectionSortOrder(_ db: GRDB.Database) throws {
        let ids = try String.fetchAll(db, sql:
            "SELECT id FROM collections ORDER BY created_at ASC, name ASC")
        for (i, id) in ids.enumerated() {
            try db.execute(sql: "UPDATE collections SET sort_order = ? WHERE id = ?",
                           arguments: [i, id])
        }
    }
}
