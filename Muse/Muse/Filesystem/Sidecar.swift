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
    /// User-authored note, per (file_id, parent_dir). Optional so pre-note
    /// sidecars decode to nil. NOT a FileRow column (`apply` never touches it).
    var note: String? = nil
    /// The CURRENT edit stack's canonical JSON, per (file_id, parent_dir).
    /// Optional so pre-edit sidecars decode unchanged. Versions/snapshots are
    /// device-local and deliberately do NOT ride sidecars (recorded
    /// limitation) — only the stack that renders everywhere syncs.
    var edit_stack: String? = nil
    /// The edit field's OWN clock, independent of `updated_at`. An edit and a
    /// tag change are separate writers of the same file, so resolving edits by
    /// the sidecar-wide clock would let an unrelated analyze-export on another
    /// device roll back an edit it never saw.
    var edit_updated_at: Int64? = nil

    static let currentSchema = 1
}

extension Sidecar {
    /// Build a sidecar from a fully-analyzed file row + its tags. Returns
    /// nil if the file has no content hash (its identity isn't established).
    static func build(from file: FileRow, tags: [TagRow], updatedAt: Int64,
                      note: String? = nil,
                      edit: (stack: String, updatedAt: Int64)? = nil) -> Sidecar? {
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
            },
            note: note,
            edit_stack: edit?.stack,
            edit_updated_at: edit?.updatedAt
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
        Sidecar.collapsingRatings(tags).map {
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
        // A note is a scalar with no union; plain LWW would let a newer
        // analyze-export from a device that never hydrated the note clobber it
        // with nil. b is the fresh (DB-derived) side at the call site
        // `merge(existing, sidecar)`: a non-nil note is never overwritten by nil,
        // and between two non-nil the fresh side wins. Genuine deletions travel
        // the manual-edit path (mergeExisting: false), which bypasses merge.
        winner.note = b.note ?? a.note
        // The edit stack resolves by its OWN field clock, not the sidecar's:
        // greater non-nil `edit_updated_at` wins, and nil never clobbers
        // (union-never-deletes). Both fields move together — carrying a stack
        // with the other side's clock would make the next merge non-monotonic.
        if let bClock = b.edit_updated_at,
           bClock >= (a.edit_updated_at ?? Int64.min) {
            winner.edit_stack = b.edit_stack
            winner.edit_updated_at = bClock
        } else if let aClock = a.edit_updated_at {
            winner.edit_stack = a.edit_stack
            winner.edit_updated_at = aClock
        } else {
            winner.edit_stack = nil
            winner.edit_updated_at = nil
        }
        // A rating is stored as a manual tag, so the union above happily keeps
        // BOTH sides' ratings — two devices that rated the same photo while
        // offline would sync to a file carrying "★★" AND "★★★", breaking the
        // one-rating-per-photo rule `StarRating.resolution` enforces everywhere
        // else. A rating is a scalar, not a set: resolve it like the other
        // scalars, newest wins, falling back to the older side when the newer
        // carries none (union semantics never delete — a genuine clear travels
        // the manual-edit path, which bypasses merge).
        let newer = (b.updated_at > a.updated_at) ? b : a
        let older = (b.updated_at > a.updated_at) ? a : b
        let survivingRating = newer.tags.first { StarRating.isRating($0.label) }
            ?? older.tags.first { StarRating.isRating($0.label) }
        winner.tags = winner.tags.filter { !StarRating.isRating($0.label) }
        if let survivingRating { winner.tags.append(survivingRating) }
        winner.tags.sort { $0.label < $1.label }
        return winner
    }

    /// Keep at most ONE rating tag, highest first.
    ///
    /// Defensive counterpart to the resolution in `merge`, applied where a
    /// sidecar becomes DB rows: a sidecar written by an older build (or merged
    /// before that fix) can carry two ratings on disk, and materializing both
    /// would reproduce the broken state locally. There are no timestamps to
    /// compare here, so the tiebreak is deterministic rather than
    /// chronological — the highest run wins.
    nonisolated static func collapsingRatings(_ tags: [SidecarTag]) -> [SidecarTag] {
        let ratings = tags.filter { StarRating.isRating($0.label) }
        guard ratings.count > 1 else { return tags }
        let keep = ratings.max { ($0.label.count) < ($1.label.count) }
        return tags.filter { !StarRating.isRating($0.label) || $0.label == keep?.label }
    }

    /// Decide the sidecar to actually persist, given the freshly-built one
    /// (`fresh`, from this device's DB) and any sidecar already on disk
    /// (`existing`). `mergeExisting` = the analyze path (full LWW/union merge).
    /// `noteAuthoritative` = this write OWNS the note field (a note edit): the
    /// fresh note wins, including a clear (nil). When it's NOT authoritative (a
    /// tag/rating/import edit that merely rewrites the sidecar), the note field
    /// must be left as the on-disk value so an unrelated edit can't wipe a note
    /// this device hasn't hydrated yet.
    /// `editAuthoritative` is the same idea for the edit field, and for the
    /// same reason: only the edit-save/reset export owns it, so a tag or
    /// rating edit can't wipe an edit stack this device hasn't hydrated. When
    /// it IS authoritative, `fresh` wins INCLUDING a clear — that's how a
    /// Reset propagates rather than being read as "nothing to say".
    static func resolveForWrite(fresh: Sidecar, existing: Sidecar?,
                                mergeExisting: Bool, noteAuthoritative: Bool,
                                editAuthoritative: Bool = false) -> Sidecar {
        guard let existing else { return fresh }
        if mergeExisting { return merge(existing, fresh) }
        var out = fresh
        if !noteAuthoritative {
            // Non-note edit: never change the synced note (preserve on-disk;
            // fall back to the fresh value only when the disk has none).
            out.note = existing.note ?? fresh.note
        }
        if !editAuthoritative {
            out.edit_stack = existing.edit_stack ?? fresh.edit_stack
            out.edit_updated_at = existing.edit_updated_at ?? fresh.edit_updated_at
        }
        return out
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
