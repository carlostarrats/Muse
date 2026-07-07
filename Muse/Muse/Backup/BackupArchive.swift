//
//  BackupArchive.swift
//  Muse
//
//  Pure, platform-neutral model for the one-file library backup. Reuses the
//  existing Sidecar for content-level per-file metadata. Membership + cover are
//  re-keyed to content_hash here (the per-machine FileRow.id is not portable).
//

import Foundation

nonisolated struct BackupRoot: Codable, Equatable, Sendable {
    var path: String
    var display_name: String
}

nonisolated struct BackupOccurrence: Codable, Equatable, Sendable {
    var original_path: String
    var basename: String
    var root_path: String?
    var parent_dir: String?
    var tags: [SidecarTag]
    /// User-authored note for this occurrence's (file_id, parent_dir). Optional
    /// so pre-note archives decode. Notes ride the occurrence, NOT meta (per-location).
    var note: String? = nil
}

nonisolated struct BackupFile: Codable, Equatable, Sendable {
    var content_hash: String
    var meta: Sidecar           // content-level fields; meta.tags stays empty
    var occurrences: [BackupOccurrence]
}

nonisolated struct BackupMember: Codable, Equatable, Sendable {
    var content_hash: String
    var added_by: String        // "auto" | "manual"
}

nonisolated struct BackupCollection: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var sort_order: Int
    var model_version: String
    var is_hidden: Int
    var cover_hash: String?
    var members: [BackupMember]
    var excluded_hashes: [String]
    // Sidebar appearance (v10). Optional so pre-appearance archives decode.
    var icon: String? = nil
    var color: String? = nil
}

nonisolated struct BackupStar: Codable, Equatable, Sendable {
    var path: String
    var display_name: String
}

nonisolated struct BackupArchive: Codable, Equatable, Sendable {
    var schema: Int
    var created_at: Int64
    var app_version: String?
    var roots: [BackupRoot]
    var files: [BackupFile]
    var collections: [BackupCollection]
    var stars: [BackupStar]

    static let currentSchema = 1
}
