//
//  Sidecar.swift
//  Muse
//
//  Portable per-asset metadata that rides iCloud Drive sync inside a
//  hidden .muse/ folder, so another device (or the eventual iOS app)
//  hydrates the full experience without re-running Vision. Pure value
//  type — no I/O, no DB. Maps to/from FileRow + TagRow.
//

import Foundation

/// One manual or vision tag, mirrored from TagRow's portable columns.
nonisolated struct SidecarTag: Codable, Equatable, Sendable {
    var label: String
    var source: String            // "manual" | "vision" | "vision-*"
    var confidence: Double?
    var model_version: String?
}

/// Complete portable record for one asset, keyed by content hash. Must
/// stay platform-neutral (no AppKit types) so iOS can read it unchanged.
nonisolated struct Sidecar: Codable, Equatable, Sendable {
    var schema: Int               // = 1
    /// When this metadata was last written (epoch seconds). Drives
    /// last-writer-wins conflict resolution — NOT the file's mtime.
    var updated_at: Int64
    var content_hash: String
    var kind: String
    var width: Int?
    var height: Int?
    var duration_seconds: Double?
    var created_at: Int64?
    var modified_at: Int64?
    var caption: String?
    var dominant_color: String?
    var palette: String?
    var feature_print: Data?      // JSONEncoder serializes Data as base64
    var analyzed_hash: String?
    var intent: String?
    var intent_model_version: String?
    var tags: [SidecarTag]

    static let currentSchema = 1
}

extension Sidecar {
    /// Build a sidecar from a fully-analyzed file row + its tags. Returns
    /// nil if the file has no content hash (its identity isn't established).
    static func build(from file: FileRow, tags: [TagRow], updatedAt: Int64) -> Sidecar? {
        guard let hash = file.content_hash else { return nil }
        return Sidecar(
            schema: Sidecar.currentSchema,
            updated_at: updatedAt,
            content_hash: hash,
            kind: file.kind,
            width: file.width,
            height: file.height,
            duration_seconds: file.duration_seconds,
            created_at: file.created_at,
            modified_at: file.modified_at,
            caption: file.caption,
            dominant_color: file.dominant_color,
            palette: file.palette,
            feature_print: file.feature_print,
            analyzed_hash: file.analyzed_hash,
            intent: file.intent,
            intent_model_version: file.intent_model_version,
            tags: tags.map {
                SidecarTag(label: $0.label, source: $0.source,
                           confidence: $0.confidence, model_version: $0.model_version)
            }
        )
    }

    /// Apply this sidecar's portable fields onto an existing file row,
    /// leaving identity/device-local columns (id, size_bytes, last_seen_at,
    /// content_hash) untouched.
    nonisolated func apply(onto file: inout FileRow) {
        file.width = width
        file.height = height
        file.duration_seconds = duration_seconds
        file.created_at = created_at
        file.modified_at = modified_at
        file.caption = caption
        file.dominant_color = dominant_color
        file.palette = palette
        file.feature_print = feature_print
        file.analyzed_hash = analyzed_hash
        file.intent = intent
        file.intent_model_version = intent_model_version
    }

    /// Materialize TagRows for a given file id, scoped to `parentDir` (the
    /// folder this sidecar lives in — tags are per-location). `makeID` supplies
    /// unique row ids (UUID in production, deterministic in tests).
    nonisolated func tagRows(fileID: String, parentDir: String?, makeID: () -> String) -> [TagRow] {
        tags.map {
            TagRow(id: makeID(), file_id: fileID, parent_dir: parentDir, label: $0.label,
                   source: $0.source, confidence: $0.confidence,
                   model_version: $0.model_version)
        }
    }
}

extension Sidecar {
    /// Deterministically merge two sidecars for the same content hash.
    /// Scalar fields come from whichever has the greater `updated_at`
    /// (ties → `a`). Tags union by label; a "manual" source always wins
    /// over a non-manual one for the same label (invariant Q32).
    static func merge(_ a: Sidecar, _ b: Sidecar) -> Sidecar {
        var winner = (b.updated_at > a.updated_at) ? b : a
        winner.updated_at = max(a.updated_at, b.updated_at)
        winner.tags = mergeTags(a.tags, b.tags)
        return winner
    }

    private static func mergeTags(_ a: [SidecarTag], _ b: [SidecarTag]) -> [SidecarTag] {
        var byLabel: [String: SidecarTag] = [:]
        for tag in a + b {
            if let existing = byLabel[tag.label] {
                let incomingManual = tag.source == "manual"
                let existingManual = existing.source == "manual"
                if incomingManual && !existingManual {
                    byLabel[tag.label] = tag
                }
                // else keep existing (manual stays, or first-seen vision stays)
            } else {
                byLabel[tag.label] = tag
            }
        }
        return byLabel.values.sorted { $0.label < $1.label }
    }
}
