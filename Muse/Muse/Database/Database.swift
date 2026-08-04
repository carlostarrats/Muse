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
            // WAL + synchronous NORMAL. The default (rollback journal,
            // synchronous FULL) makes EVERY write transaction a journal
            // create/fsync/delete, and this app commits in small transactions
            // constantly: per index batch, per analyzed file, per tag edit,
            // per backfill chunk, and — unavoidably, since each depends on its
            // own header read — once per file during an import. WAL is the
            // configuration SQLite documents for exactly that write pattern.
            //
            // Durability: with NORMAL, a power loss can cost the last few
            // committed transactions but cannot corrupt the database. What
            // those transactions carry is derived metadata that the next
            // analyze/index pass regenerates — the library's truth is the
            // files on disk, and the backup archive is built separately (it
            // never copies this file).
            //
            // Single writer, single process: the share extension does not open
            // the database.
            config.prepareDatabase { db in
                // journal_mode is persistent in the file header, so this is a
                // no-op after the first open; synchronous is per-connection
                // and must be set every time.
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
            }
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

        migrator.registerMigration("v22_photo_stats") { db in
            // Capture statistics, on the EXISTING photo_traits table — Spec 03's
            // version-bump mechanism used as designed. Bumping
            // PhotoTraits.currentVersion leaves every existing row
            // version-behind, so DeepAnalysisBackfill re-scans them under its
            // standing per-launch cap; no new marker, table or index.
            //
            // These are computed at FIXED thresholds (ClippingStats.stored*),
            // never the user's zebra prefs — a stored row must not change
            // meaning when a slider moves.
            try db.alter(table: "photo_traits") { t in
                t.add(column: "clip_high_r", .double)
                t.add(column: "clip_high_g", .double)
                t.add(column: "clip_high_b", .double)
                t.add(column: "clip_low", .double)
                t.add(column: "noise_sigma", .double)
            }
        }

        migrator.registerMigration("v23_edit_luts") { db in
            // Library-global LUT storage, content-addressed: the PK IS the
            // SHA-256 of the canonical float bytes, so a `lutHash` in a stack
            // resolves to byte-identical data or to nothing. Rows are
            // IMMUTABLE — import is INSERT OR IGNORE, rename touches `name`
            // only, and there is no update path.
            try db.create(table: "edit_luts") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("data", .blob).notNull()       // float32 RGB, R fastest-varying
                t.column("created_at", .integer).notNull()
            }
        }

        migrator.registerMigration("v24_per_file_identity") { db in
            // Identity becomes the FILE ON DISK, not its bytes.
            //
            // `files.content_hash` was UNIQUE, so N byte-identical files
            // collapsed onto ONE row. Everything the user authors hangs off
            // that row — the edit stack, tags, ratings, the note, collection
            // membership — so twelve copies shared one of each. Editing one
            // changed all twelve. That is the reported bug, from the owner's
            // own library: twelve `RAW_SONY_ILCA-77M2*.ARW` in one folder,
            // twelve alive paths, ONE `edits` row.
            //
            // Content is still COMPARED — Find Duplicates groups by it, and
            // identical pixels must not be analyzed twelve times — but it is
            // no longer identity.
            //
            // Two rules govern what gets copied to each new row:
            //
            //   * content-DERIVED data (EXIF, traits, place, embeddings, and
            //     the analysis columns on `files` itself) is copied because it
            //     is identical for identical bytes. Recomputing it per copy
            //     would mean N Vision passes over the same pixels, and leaving
            //     it out would make every copy look unanalyzed.
            //   * USER-authored data is copied because the owner's rule is
            //     that a copy INHERITS (see the design doc §3). Nothing
            //     visible today is lost; the copies diverge from the next
            //     edit forward.
            //
            // The lowest absolute_path keeps the original row, so the split is
            // deterministic and re-runnable.

            // 1. Rebuild `files` without the UNIQUE on content_hash. SQLite
            //    cannot drop an inline constraint, and this is the standard
            //    create/copy/drop/rename. It is SAFE here only because GRDB
            //    runs migrations with `PRAGMA foreign_keys = OFF` by default
            //    (ForeignKeyChecks.deferred) — with foreign keys ON, the
            //    DROP would cascade-delete every paths, tags, notes and edits
            //    row in the library. Do not "helpfully" mark this migration
            //    `.immediate`.
            try db.execute(sql: """
                CREATE TABLE files_new (
                    id TEXT PRIMARY KEY NOT NULL,
                    content_hash TEXT,
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
                    feature_print BLOB,
                    palette TEXT,
                    analyzed_hash TEXT,
                    intent TEXT,
                    intent_model_version TEXT,
                    lat DOUBLE,
                    lon DOUBLE,
                    coords_scanned_hash TEXT,
                    last_viewed_at INTEGER
                )
                """)
            try db.execute(sql: """
                INSERT INTO files_new (id, content_hash, kind, size_bytes, width, height,
                    duration_seconds, created_at, modified_at, last_seen_at, caption,
                    dominant_color, feature_print, palette, analyzed_hash, intent,
                    intent_model_version, lat, lon, coords_scanned_hash, last_viewed_at)
                SELECT id, content_hash, kind, size_bytes, width, height,
                    duration_seconds, created_at, modified_at, last_seen_at, caption,
                    dominant_color, feature_print, palette, analyzed_hash, intent,
                    intent_model_version, lat, lon, coords_scanned_hash, last_viewed_at
                FROM files
                """)
            try db.execute(sql: "DROP TABLE files")
            try db.execute(sql: "ALTER TABLE files_new RENAME TO files")
            // content_hash keeps an index — it is still the grouping key for
            // Find Duplicates and for analysis reuse — just not a unique one.
            try db.execute(sql: "CREATE INDEX files_content_hash_idx ON files(content_hash)")
            // DROP TABLE takes every index on it with it, including ones added
            // by LATER migrations than the one that created the table. v13's
            // partial coordinate index is the case in point — losing it turns
            // every `near:` / `in:` / `.location` query into a full scan, with
            // nothing failing loudly to say so. Any future rebuild of `files`
            // has to re-create this list.
            try db.execute(sql: """
                CREATE INDEX files_coords_idx ON files(lat, lon) WHERE lat IS NOT NULL
                """)

            // 2. Split. Every alive path beyond the first, per file.
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.id AS path_id, p.file_id AS file_id, p.absolute_path AS path
                FROM paths p
                WHERE p.is_alive = 1
                  AND p.file_id IN (SELECT file_id FROM paths
                                    WHERE is_alive = 1 AND file_id IS NOT NULL
                                    GROUP BY file_id HAVING COUNT(*) > 1)
                ORDER BY p.file_id, p.absolute_path
                """)

            var kept: Set<String> = []
            for row in rows {
                guard let pathID: String = row["path_id"],
                      let oldID: String = row["file_id"],
                      let absPath: String = row["path"] else { continue }
                // The first (lowest) path of each file keeps the original row.
                if kept.insert(oldID).inserted { continue }

                let newID = UUID().uuidString
                let dir = (absPath as NSString).deletingLastPathComponent
                let base = (absPath as NSString).lastPathComponent

                try db.execute(sql: """
                    INSERT INTO files (id, content_hash, kind, size_bytes, width, height,
                        duration_seconds, created_at, modified_at, last_seen_at, caption,
                        dominant_color, feature_print, palette, analyzed_hash, intent,
                        intent_model_version, lat, lon, coords_scanned_hash, last_viewed_at)
                    SELECT ?, content_hash, kind, size_bytes, width, height,
                        duration_seconds, created_at, modified_at, last_seen_at, caption,
                        dominant_color, feature_print, palette, analyzed_hash, intent,
                        intent_model_version, lat, lon, coords_scanned_hash, last_viewed_at
                    FROM files WHERE id = ?
                    """, arguments: [newID, oldID])

                // Content-derived rows.
                try db.execute(sql: """
                    INSERT INTO photo_meta SELECT ?, exif_scanned_hash, capture_date,
                        capture_md, camera_make, camera_model, lens, iso, f_number,
                        exposure_seconds, focal_length, focal_length_35mm, flash_fired
                    FROM photo_meta WHERE file_id = ?
                    """, arguments: [newID, oldID])
                try db.execute(sql: """
                    INSERT INTO photo_traits SELECT ?, traits_scanned_hash, traits_version,
                        face_count, largest_face_frac, face_quality, pet_count, sharpness,
                        clip_high_r, clip_high_g, clip_high_b, clip_low, noise_sigma
                    FROM photo_traits WHERE file_id = ?
                    """, arguments: [newID, oldID])
                try db.execute(sql: """
                    INSERT INTO places SELECT ?, geocoded_hash, dataset_version,
                        city, admin, country, place_key
                    FROM places WHERE file_id = ?
                    """, arguments: [newID, oldID])
                try db.execute(sql: """
                    INSERT INTO embeddings SELECT ?, vector, model_version, updated_at
                    FROM embeddings WHERE file_id = ?
                    """, arguments: [newID, oldID])
                try db.execute(sql: """
                    INSERT INTO clip_embeddings SELECT ?, embedded_hash, model_generation, vector
                    FROM clip_embeddings WHERE file_id = ?
                    """, arguments: [newID, oldID])

                // FTS carries THIS path's own basename. One FTS row could only
                // hold one name, so before this migration eleven of twelve
                // copies were unfindable by the name on disk.
                try db.execute(sql: """
                    INSERT INTO files_fts (file_id, basename, ocr_text, caption)
                    SELECT ?, ?, ocr_text, caption FROM files_fts WHERE file_id = ?
                    """, arguments: [newID, base, oldID])

                // User-authored data for THIS path's folder. Same-folder copies
                // each get their own copy of what they were sharing;
                // cross-folder copies take only their own folder's rows.
                try db.execute(sql: """
                    INSERT INTO tags (id, file_id, parent_dir, label, source, confidence, model_version)
                    SELECT lower(hex(randomblob(16))), ?, parent_dir, label, source,
                           confidence, model_version
                    FROM tags WHERE file_id = ? AND parent_dir = ?
                    """, arguments: [newID, oldID, dir])
                try db.execute(sql: """
                    INSERT INTO notes (file_id, parent_dir, body, updated_at)
                    SELECT ?, parent_dir, body, updated_at
                    FROM notes WHERE file_id = ? AND parent_dir = ?
                    """, arguments: [newID, oldID, dir])
                try db.execute(sql: """
                    INSERT INTO edits (file_id, parent_dir, stack, stack_hash,
                                       process_version, updated_at)
                    SELECT ?, parent_dir, stack, stack_hash, process_version, updated_at
                    FROM edits WHERE file_id = ? AND parent_dir = ?
                    """, arguments: [newID, oldID, dir])
                try db.execute(sql: """
                    INSERT INTO edit_versions (id, file_id, parent_dir, kind, name, stack, created_at)
                    SELECT lower(hex(randomblob(16))), ?, parent_dir, kind, name, stack, created_at
                    FROM edit_versions WHERE file_id = ? AND parent_dir = ?
                    """, arguments: [newID, oldID, dir])

                // Collections: every copy is a member today, so keep it one.
                try db.execute(sql: """
                    INSERT OR IGNORE INTO collection_members (collection_id, file_id, added_by)
                    SELECT collection_id, ?, added_by FROM collection_members WHERE file_id = ?
                    """, arguments: [newID, oldID])
                try db.execute(sql: """
                    INSERT OR IGNORE INTO collection_exclusions (collection_id, file_id)
                    SELECT collection_id, ? FROM collection_exclusions WHERE file_id = ?
                    """, arguments: [newID, oldID])

                // Re-point the path. DEAD paths stay on the original row —
                // they are how a re-appearing file is revived, and they have
                // no folder of their own to reason about.
                try db.execute(sql: "UPDATE paths SET file_id = ? WHERE id = ?",
                               arguments: [newID, pathID])
            }

            // Sweep per-location rows stranded on a folder their row no longer
            // occupies. The copy above is a COPY, not a move — correct for the
            // same-folder case, where the original keeps its own rows — but for
            // a CROSS-folder split the original row keeps a `/B` tag it can no
            // longer reach, because its only alive path is now in `/A`.
            //
            // Unreachable rather than harmful today: every read scopes by the
            // file's own folder. It is swept anyway because `parent_dir` is
            // redundant under per-file identity and is expected to be dropped —
            // and at that moment two rows differing only by `parent_dir`
            // collapse onto one primary key and the migration fails.
            //
            // Rows on a file with NO alive path are left alone: that is v7's
            // deliberate NULL-scope orphan case, whose lifecycle belongs to
            // housekeeping.
            let alive = try Row.fetchAll(db, sql: """
                SELECT file_id, absolute_path FROM paths
                WHERE is_alive = 1 AND file_id IS NOT NULL
                """)
            for row in alive {
                guard let fid: String = row["file_id"],
                      let path: String = row["absolute_path"] else { continue }
                let dir = (path as NSString).deletingLastPathComponent
                for table in ["tags", "notes", "edits", "edit_versions"] {
                    try db.execute(sql: """
                        DELETE FROM \(table)
                        WHERE file_id = ? AND parent_dir IS NOT NULL AND parent_dir <> ?
                        """, arguments: [fid, dir])
                }
            }

            // Derived caches keyed on the old identities. The next Find
            // Duplicates run rebuilds them from scratch.
            try db.execute(sql: "DELETE FROM duplicate_members")
            try db.execute(sql: "DELETE FROM duplicate_groups")
        }

        migrator.registerMigration("v25_per_file_identity_repair") { db in
            // Two things v24 got wrong, found by querying a real library after
            // it ran rather than by reading the migration again.
            //
            // Both are repairs, not new schema, and both are idempotent — which
            // is the point: v24 is append-only and already applied on machines
            // that ran the intermediate build, so fixing v24 in place would
            // silently skip exactly the databases that need it.

            // 1. `DROP TABLE files` takes every index with it, including ones
            //    created by LATER migrations than the one that made the table.
            //    v13's partial coordinate index was collateral, and losing it
            //    turns every `near:` / `in:` / `.location` query into a full
            //    scan with nothing failing loudly to say so.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS files_coords_idx
                ON files(lat, lon) WHERE lat IS NOT NULL
                """)

            // 2. v24 wrote each NEW row's FTS basename from its own path, but
            //    left the KEPT row's alone — and the kept row carried whatever
            //    name the shared row had been analyzed under, which is only by
            //    luck its own. In the owner's library the file
            //    `RAW_SONY_ILCA-77M2 copy 2 2 2.ARW` was searchable only as
            //    `RAW_SONY_ILCA-77M2.ARW`; seven files were affected.
            //
            //    Repaired for EVERY alive path, not just split ones: the same
            //    drift predates per-file identity (an external rename left the
            //    old name in FTS whenever a row had several paths), so this
            //    sweeps that too.
            let alive = try Row.fetchAll(db, sql: """
                SELECT file_id, absolute_path FROM paths
                WHERE is_alive = 1 AND file_id IS NOT NULL
                """)
            for row in alive {
                guard let fid: String = row["file_id"],
                      let path: String = row["absolute_path"] else { continue }
                let base = (path as NSString).lastPathComponent
                try db.execute(sql: """
                    UPDATE files_fts SET basename = ?
                    WHERE file_id = ? AND basename <> ?
                    """, arguments: [base, fid, base])
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
