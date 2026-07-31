//
//  Records.swift
//  Muse
//
//  GRDB row types matching the schema in Database.swift. Stored
//  separately from the in-memory FileNode value type (which is for the
//  enumerated-stage grid view); these are the persisted rows.
//

import Foundation
import GRDB

struct FileRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "files"

    var id: String
    var content_hash: String?
    var kind: String
    var size_bytes: Int64?
    var width: Int?
    var height: Int?
    var duration_seconds: Double?
    var created_at: Int64?
    var modified_at: Int64?
    var last_seen_at: Int64
    var caption: String?
    var dominant_color: String?
    var feature_print: Data?
    var palette: String?
    /// content_hash at the time of the last Vision analysis; mismatch (or
    /// nil) marks the file as needing (re)analysis.
    var analyzed_hash: String?
    /// One of IntentBucket.rawValue for a classified screenshot, else nil.
    var intent: String?
    /// Classifier model version that last set `intent` (drives one-time backfill).
    var intent_model_version: String?
    /// WGS-84 latitude read from the file's own header (EXIF GPS / ISO-6709).
    var lat: Double?
    /// WGS-84 longitude, same source as `lat`.
    var lon: Double?
    /// content_hash at the time of the last GPS read — the attempted-marker that
    /// stops a GPS-less file being re-opened on every launch forever. Mirrors
    /// `analyzed_hash`.
    var coords_scanned_hash: String?
    /// Unix seconds this file was last opened in the viewer. Device-local
    /// behavioral data (v16): never exported to a sidecar, never synced.
    var last_viewed_at: Int64?

    enum Columns {
        static let id = Column("id")
        static let content_hash = Column("content_hash")
        static let last_seen_at = Column("last_seen_at")
        static let feature_print = Column("feature_print")
    }
}

struct PathRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "paths"

    var id: String
    var file_id: String?
    var absolute_path: String
    var bookmark_data: Data?
    var is_alive: Int

    enum Columns {
        static let id = Column("id")
        static let file_id = Column("file_id")
        static let absolute_path = Column("absolute_path")
        static let is_alive = Column("is_alive")
    }
}

struct TagRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "tags"

    var id: String
    var file_id: String
    /// Parent folder of the file this tag belongs to. Tags are per-location:
    /// the same content in another folder is a different image with its own
    /// tags. Nil only for orphaned tags (no alive path) — never surfaced.
    var parent_dir: String?
    var label: String
    var source: String
    var confidence: Double?
    var model_version: String?

    enum Columns {
        static let file_id = Column("file_id")
        static let parent_dir = Column("parent_dir")
        static let label = Column("label")
        static let source = Column("source")
    }
}

struct NoteRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "notes"

    /// File this note belongs to, scoped to its folder — notes are per-location
    /// like tags (a duplicate in another folder has its own note).
    var file_id: String
    var parent_dir: String
    var body: String
    /// Epoch seconds of the last write; feeds the sidecar's last-writer-wins.
    var updated_at: Int64

    enum Columns {
        static let file_id = Column("file_id")
        static let parent_dir = Column("parent_dir")
        static let body = Column("body")
    }
}

struct StarredFolderRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "starred_folders"

    var id: String
    var absolute_path: String
    var bookmark_data: Data?
    var display_name: String
    var added_at: Int64
}

struct DuplicateGroupRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "duplicate_groups"
    var id: String
    var reason: String
    var created_at: Int64
}

struct DuplicateMemberRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "duplicate_members"
    var group_id: String
    var file_id: String
    var is_suggested_keeper: Int
}

struct EmbeddingRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "embeddings"
    var file_id: String
    var vector: Data
    var model_version: String
    var updated_at: Int64
}

struct CollectionRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "collections"
    var id: String
    var name: String
    var is_hidden: Int
    var model_version: String
    var created_at: Int64
    var updated_at: Int64
    var cover_file_id: String?      // user-chosen cover; nil = auto (first member)
    var sort_order: Int = 0         // sidebar-only manual order (v8)
    var icon: String?               // sidebar SF Symbol name; nil = default (v10)
    var color: String?              // sidebar icon color token; nil = default (v10)
    var smart_rules: String?        // JSON SmartRuleSet; nil = not a smart collection (v12)
}

struct CollectionMemberRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "collection_members"
    var collection_id: String
    var file_id: String
    var added_by: String          // "auto" | "manual"
}

/// EXIF read from the file's own header (v14). Content-keyed like coordinates:
/// two byte-identical copies have identical EXIF by definition.
struct PhotoMetaRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "photo_meta"
    var file_id: String
    /// content_hash at the time of the last EXIF read — the attempted-marker,
    /// same role as `files.coords_scanned_hash`.
    var exif_scanned_hash: String?
    var capture_date: Int64?        // unix seconds, DateTimeOriginal in local time
    var capture_md: String?         // "MM-DD" — materialized on-this-day key
    var camera_make: String?
    var camera_model: String?
    var lens: String?
    var iso: Int?
    var f_number: Double?
    var exposure_seconds: Double?
    var focal_length: Double?       // mm
    var focal_length_35mm: Int?
    var flash_fired: Bool?          // EXIF Flash bit 0; nil = unknown
}

/// Offline reverse-geocoding result (v15). The row's mere existence is the
/// attempted-marker: NULL place fields mean "geocoded, nothing within range".
struct PlaceRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "places"
    var file_id: String
    var geocoded_hash: String
    var dataset_version: Int
    var city: String?
    var admin: String?
    /// ISO 3166-1 alpha-2 code — display names resolve at render time.
    var country: String?
    /// Lowercased "city|admin|country"; nil when nothing was within range.
    var place_key: String?
}

/// A near-duplicate stack (v17). Presentation-only: sets of file ids, never
/// paths, tags, ratings, notes or collection membership.
struct StackRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "stacks"
    var id: String
    var kind: String                // "auto" | "manual"
    /// Permanent tombstone — an unstacked stack keeps its row and members so
    /// the auto-stacker never re-forms it. Never cleaned up.
    var dissolved: Bool
    var pick_file_id: String?
    var created_at: Int64
}

struct StackMemberRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "stack_members"
    var stack_id: String
    var file_id: String
}

/// Raster-derived per-photo traits (v19): faces, pets, sharpness — every
/// scalar a single decode can produce. Content-keyed like `palette`, never the
/// `(file_id, parent_dir)` grain tags/notes/ratings use.
///
/// A row with NULL trait fields is an ATTEMPTED-MARKER (the file was reached
/// and couldn't be decoded), not absence — absence of the row entirely means
/// unscanned, which is why `faces:0` matches only files that have a row.
struct PhotoTraitsRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "photo_traits"

    var file_id: String
    var traits_scanned_hash: String
    var traits_version: Int
    var face_count: Int?
    var largest_face_frac: Double?
    var face_quality: Double?
    var pet_count: Int?
    var sharpness: Double?

    enum Columns {
        static let file_id = Column("file_id")
        static let traits_scanned_hash = Column("traits_scanned_hash")
        static let traits_version = Column("traits_version")
        static let face_count = Column("face_count")
        static let pet_count = Column("pet_count")
    }
}

/// Bump when a NEW trait is added to `photo_traits` — the backfill re-selects
/// every row whose `traits_version` is behind, so a new trait needs no new
/// marker column and no parallel table.
nonisolated enum PhotoTraits {
    static let currentVersion = 1
}

/// A CLIP image embedding (v18). fp16, L2-normalized, content-keyed.
/// `model_generation` pins the vector to the model that produced it —
/// vectors from different generations must never be compared.
struct ClipEmbeddingRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "clip_embeddings"

    var file_id: String
    var embedded_hash: String
    var model_generation: Int
    /// NULL is an attempted-marker (reached, couldn't embed) — the backfill
    /// must not retry it at the same generation every launch.
    var vector: Data?

    enum Columns {
        static let file_id = Column("file_id")
        static let embedded_hash = Column("embedded_hash")
        static let model_generation = Column("model_generation")
        static let vector = Column("vector")
    }
}

/// The CURRENT edit stack for one file IN ONE FOLDER (v20). Per
/// `(file_id, parent_dir)` like tags and notes — never content-keyed.
/// A neutral stack has NO row; the absence is the "unedited" state.
struct EditRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "edits"

    var file_id: String
    var parent_dir: String
    /// Canonical `.sortedKeys` JSON — see `EditStackCodec`.
    var stack: String
    /// SHA-256 of `stack`; the thumbnail cache key's edit component.
    var stack_hash: String
    /// Denormalized from the blob so a renderer can refuse a newer stack
    /// without decoding it.
    var process_version: Int
    /// Epoch seconds; the sidecar's `edit_updated_at` field clock.
    var updated_at: Int64

    enum Columns {
        static let file_id = Column("file_id")
        static let parent_dir = Column("parent_dir")
        static let stack_hash = Column("stack_hash")
        static let updated_at = Column("updated_at")
    }
}

/// A saved version or snapshot of an edit stack (v20). Same table, same
/// shape; `kind` decides which surface offers it.
struct EditVersionRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "edit_versions"

    var id: String
    var file_id: String
    var parent_dir: String
    /// "version" (the switcher + grid badge count) | "snapshot" (the
    /// before/after compare picker).
    var kind: String
    var name: String
    var stack: String
    var created_at: Int64

    enum Columns {
        static let id = Column("id")
        static let file_id = Column("file_id")
        static let parent_dir = Column("parent_dir")
        static let kind = Column("kind")
        static let created_at = Column("created_at")
    }
}

/// A library-global look (v21). Stored MINUS the geometry group.
struct EditPresetRow: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "edit_presets"

    var id: String
    var name: String
    var stack: String
    var created_at: Int64
    var updated_at: Int64

    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
    }
}
