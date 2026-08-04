//
//  SidecarHydrator.swift
//  Muse
//
//  On folder load, imports current `.muse/<hash>.json` sidecars into the
//  local SQLite (FileRow + tags + FTS + analyzed_hash) so the automatic
//  analysis pass skips already-described files. This is what lets an
//  iCloud-only / fresh device reconstruct the experience without re-running
//  Vision. Pure mapping lives in Sidecar; this is the thin DB writer.
//

import Foundation
import GRDB

enum SidecarHydrator {
    /// Whether a local row already holds everything a sidecar could describe,
    /// so the read can be skipped.
    ///
    /// `analyzed_hash == content_hash` means "Vision has described these
    /// bytes" — a valid shortcut ONLY for the kinds Vision describes. Non-image
    /// kinds are stamped too (so `analyzePending` stops re-queuing a PDF on
    /// every folder visit), and that stamp says nothing about the sidecar's
    /// contents: treating it as "nothing to import" would permanently block a
    /// note, rating, manual tag or edit made on another device from arriving
    /// for a PDF, video, archive or document. Silent, and it would surface only
    /// as "my note didn't sync".
    ///
    /// Pure so the rule is testable without a DB or a sidecar on disk, and
    /// `nonisolated` because it is consulted from inside a GRDB read closure.
    nonisolated static func alreadyDescribed(kind: String, analyzedHash: String?,
                                             contentHash: String) -> Bool {
        guard let analyzedHash, analyzedHash == contentHash else { return false }
        return AssetKind(rawValue: kind)?.isPhotoKind ?? false
    }

    /// For each url in the iCloud zone, if a matching sidecar exists and is
    /// current (sidecar.analyzed_hash == the file's content_hash), apply it.
    static func hydrate(urls: [URL], folder: URL?) async {
        guard folder != nil, let queue = Database.shared.dbQueue else { return }
        for url in urls {
            guard ICloudZone.contains(url, folder: folder) else { continue }
            let absPath = url.standardizedFileURL.path
            // Resolve the file id + current content hash.
            let info: (id: String, hash: String)? = try? await queue.read { db -> (id: String, hash: String)? in
                guard let path = try PathRow
                        .filter(PathRow.Columns.absolute_path == absPath)
                        .filter(PathRow.Columns.is_alive == 1).fetchOne(db),
                      let fid = path.file_id,
                      let file = try FileRow.filter(FileRow.Columns.id == fid).fetchOne(db),
                      let hash = file.content_hash else { return nil }
                // Already described at this content — nothing to import.
                if alreadyDescribed(kind: file.kind, analyzedHash: file.analyzed_hash,
                                    contentHash: hash) { return nil }
                return (fid, hash)
            } ?? nil
            guard let info else { continue }
            guard let sidecar = SidecarStore.read(forAsset: url, contentHash: info.hash),
                  sidecar.analyzed_hash == info.hash else { continue }
            await apply(sidecar, fileID: info.id, parentDir: TagScope.parentDir(of: url),
                        basename: url.lastPathComponent, queue: queue)
            // A hydrated edit has to reach the provider index and the
            // thumbnail cache, or the file keeps rendering as it was until the
            // next launch. Same consequences as a local save, minus the
            // sidecar re-export — that would bounce the edit straight back at
            // the device that sent it.
            if sidecar.edit_updated_at != nil {
                await EditStore.shared.applyHydratedConsequences(for: [url])
            }
        }
    }

    // internal (not private) so the rating-exclusivity rule can be tested
    // against a real DB rather than only at the pure-helper level.
    static func apply(_ sidecar: Sidecar, fileID: String, parentDir: String,
                              basename: String, queue: DatabaseQueue) async {
        try? await queue.write { db in
            if var file = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db) {
                sidecar.apply(onto: &file)
                try file.update(db)
            }
            // A rating is a manual tag but is MUTUALLY EXCLUSIVE, and the insert
            // below only skips a tag whose exact label already exists — so a
            // sidecar rating of "★★★★" would land alongside a local "★★" and
            // leave the file carrying two. Ratings are therefore only hydrated
            // onto a file that has NONE locally: a rating the user set on THIS
            // device is never overwritten by a syncing one, which matches how
            // `NoteStore.applyHydrated` protects a newer local note.
            let hasLocalRating = try TagRow
                .filter(TagRow.Columns.file_id == fileID)
                .filter(TagRow.Columns.parent_dir == parentDir)
                .fetchAll(db)
                .contains { StarRating.isRating($0.label) }

            // Tags: insert sidecar tags scoped to this folder, honoring
            // manual-beats-vision (Q32) per (file_id, parent_dir).
            for t in sidecar.tagRows(fileID: fileID, parentDir: parentDir, makeID: { UUID().uuidString }) {
                if hasLocalRating && StarRating.isRating(t.label) { continue }
                if let existing = try TagRow
                    .filter(TagRow.Columns.file_id == fileID)
                    .filter(TagRow.Columns.parent_dir == parentDir)
                    .filter(TagRow.Columns.label == t.label).fetchOne(db) {
                    if existing.source != "manual" && t.source == "manual" {
                        var u = existing; u.source = "manual"; u.confidence = nil
                        u.model_version = nil; try u.update(db)
                    }
                } else {
                    var row = t; try row.insert(db)
                }
            }
            // Note: last-writer-wins upsert for this folder (nil/empty deletes,
            // but only when the sidecar is newer than any local note — see
            // NoteStore.applyHydrated).
            try NoteStore.applyHydrated(sidecar.note, fileID: fileID, parentDir: parentDir,
                                        incomingUpdatedAt: sidecar.updated_at, db: db)
            // The edit stack is row-level LWW on its OWN clock, not the
            // sidecar's: an analyze-export from a device that never saw the
            // edit carries a newer `updated_at` but an older (or absent)
            // `edit_updated_at`, and must not roll the edit back. A sidecar
            // carrying no edit clock at all says nothing about edits, so it's
            // skipped rather than treated as a synced reset.
            if let editClock = sidecar.edit_updated_at {
                try EditRecordStore.applyHydrated(json: sidecar.edit_stack,
                                                  incomingUpdatedAt: editClock,
                                                  fileID: fileID, parentDir: parentDir, db: db)
            }
            // FTS5 — mirror AnalyzePipeline's keying.
            try db.execute(sql: "DELETE FROM files_fts WHERE file_id = ?", arguments: [fileID])
            try db.execute(sql: """
                INSERT INTO files_fts(file_id, basename, ocr_text, caption)
                VALUES (?, ?, ?, ?)
            """, arguments: [fileID, basename, "", sidecar.caption ?? ""])
        }
    }
}
