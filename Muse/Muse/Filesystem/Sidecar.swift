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
struct SidecarTag: Codable, Equatable, Sendable {
    var label: String
    var source: String            // "manual" | "vision" | "vision-*"
    var confidence: Double?
    var model_version: String?
}

/// Complete portable record for one asset, keyed by content hash. Must
/// stay platform-neutral (no AppKit types) so iOS can read it unchanged.
struct Sidecar: Codable, Equatable, Sendable {
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
