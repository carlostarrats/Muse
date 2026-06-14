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
    var label: String
    var source: String
    var confidence: Double?
    var model_version: String?

    enum Columns {
        static let file_id = Column("file_id")
        static let label = Column("label")
        static let source = Column("source")
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
}

struct CollectionMemberRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "collection_members"
    var collection_id: String
    var file_id: String
    var added_by: String          // "auto" | "manual"
}
