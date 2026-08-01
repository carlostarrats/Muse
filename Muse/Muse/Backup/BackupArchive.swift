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
    /// The CURRENT edit stack for this occurrence's (file_id, parent_dir) —
    /// canonical `EditStackCodec` JSON. Optional so pre-A2 archives decode, and
    /// ABSENT for an unedited file: "no edit" is the absence of a row in
    /// `edits` and that carries into the archive unchanged.
    ///
    /// Edits ride the OCCURRENCE, not `meta`, for the same reason notes do —
    /// they are per (file_id, parent_dir), so the same bytes in two folders can
    /// carry two different stacks.
    var edit_stack: String? = nil
    var edit_updated_at: Int64? = nil
    /// The user's saved versions and snapshots for this occurrence. These are
    /// virtual copies, and a backup's job is device recovery — the "sidecars
    /// don't carry versions" rule is a SYNC rule, not a backup one.
    var edit_versions: [BackupEditVersion]? = nil
}

nonisolated struct BackupEditVersion: Codable, Equatable, Sendable {
    var kind: String            // "version" | "snapshot"
    var name: String?
    var stack: String
    var created_at: Int64
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
    // Smart-collection rules (v12). Optional so pre-smart archives decode.
    var smart_rules: String? = nil
}

nonisolated struct BackupStar: Codable, Equatable, Sendable {
    var path: String
    var display_name: String
}

/// Library-global look. Carried whole — a preset is a few hundred bytes.
nonisolated struct BackupEditPreset: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var stack: String
    var created_at: Int64
    var updated_at: Int64
}

/// Library-global LUT, content-addressed (`id` IS the SHA-256 of `data`).
///
/// **The bytes are carried deliberately.** A restored stack that references an
/// absent LUT renders as the ORIGINAL everywhere (the unresolvable-LUT rule),
/// so an archive that restored edits but dropped every look would be a
/// half-restore that looks like data loss. `CubeLUTParser.maxSize` bounds a
/// single LUT to ≤25 MB of float32 (+33% as base64 in the JSON), and taking a
/// backup is an explicit user action — accepted.
nonisolated struct BackupLut: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var size: Int
    var data: Data
}

nonisolated struct BackupArchive: Codable, Equatable, Sendable {
    var schema: Int
    var created_at: Int64
    var app_version: String?
    var roots: [BackupRoot]
    var files: [BackupFile]
    var collections: [BackupCollection]
    var stars: [BackupStar]
    // Edit assets are LIBRARY-GLOBAL, so they sit here rather than on a file.
    // Optional so pre-A2 archives decode.
    var edit_presets: [BackupEditPreset]? = nil
    var edit_luts: [BackupLut]? = nil

    /// Stays 1. Every field added since has been optional-with-nil-default, so
    /// a pre-A2 archive decodes into this shape unchanged and a post-A2 archive
    /// decodes on a pre-A2 build minus the new keys (Codable ignores unknown
    /// keys). Bumping the schema would reject archives both directions for no
    /// gain — the optional-field pattern is the compatibility mechanism.
    static let currentSchema = 1
}
