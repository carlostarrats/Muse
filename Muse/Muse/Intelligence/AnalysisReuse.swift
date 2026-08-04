//
//  AnalysisReuse.swift
//  Muse
//
//  Vision runs ONCE per distinct content, however many copies of it exist.
//
//  Per-file identity gives every file on disk its own row, which is what the
//  user wants — but analysis is derived from the PIXELS, and identical pixels
//  give identical answers. Without this seam, twelve byte-identical RAWs would
//  each pay for a full classify + OCR + palette + CLIP pass over the same
//  image: twelve times the work for one answer.
//
//  There are two doors into that waste and each has its own guard:
//
//    * a copy discovered while its original is already analyzed — closed by
//      `Indexer.inherit`, at index time;
//    * a copy indexed while its twin was still unanalyzed, now sitting in the
//      analyze queue behind it — closed HERE, at analyze time.
//
//  `nonisolated` statics taking a GRDB `Database`, the `NoteStore` shape, so
//  they run inside any write closure and unit-test against an in-memory queue.
//

import Foundation
import GRDB

nonisolated enum AnalysisReuse {

    /// Copy an already-analyzed twin's results onto `fileID`, or return false
    /// when there is no twin worth adopting from.
    ///
    /// Returns true only when the caller may SKIP its Vision pass entirely.
    @discardableResult
    static func adopt(db: GRDB.Database, fileID: String, hash: String) throws -> Bool {
        // A donor must be analyzed AT THESE BYTES. `analyzed_hash = content_hash`
        // is the freshness test the rest of the pipeline uses; a donor edited
        // since its last pass carries results describing different pixels.
        guard let donorID = try String.fetchOne(db, sql: """
            SELECT id FROM files
            WHERE content_hash = ? AND id <> ?
              AND analyzed_hash IS NOT NULL AND analyzed_hash = content_hash
            ORDER BY id LIMIT 1
            """, arguments: [hash, fileID])
        else { return false }

        // The target's own folder — vision tags are stored per
        // (file_id, parent_dir) and belong in the folder this copy lives in.
        let targetDir = try String.fetchOne(db, sql: """
            SELECT absolute_path FROM paths
            WHERE file_id = ? AND is_alive = 1 ORDER BY absolute_path LIMIT 1
            """, arguments: [fileID]).map { TagScope.parentDir(ofPath: $0) }

        // Analysis columns, including analyzed_hash — which is what takes the
        // file out of the pending set.
        try db.execute(sql: """
            UPDATE files SET
                width = d.width, height = d.height, caption = d.caption,
                dominant_color = d.dominant_color, feature_print = d.feature_print,
                palette = d.palette, analyzed_hash = d.analyzed_hash,
                intent = d.intent, intent_model_version = d.intent_model_version,
                lat = d.lat, lon = d.lon, coords_scanned_hash = d.coords_scanned_hash
            FROM (SELECT * FROM files WHERE id = ?) AS d
            WHERE files.id = ?
            """, arguments: [donorID, fileID])

        // Derived rows. INSERT OR IGNORE throughout so a second pass is a
        // no-op rather than a constraint failure.
        try db.execute(sql: """
            INSERT OR IGNORE INTO photo_meta SELECT ?, exif_scanned_hash, capture_date,
                capture_md, camera_make, camera_model, lens, iso, f_number,
                exposure_seconds, focal_length, focal_length_35mm, flash_fired
            FROM photo_meta WHERE file_id = ?
            """, arguments: [fileID, donorID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO photo_traits SELECT ?, traits_scanned_hash, traits_version,
                face_count, largest_face_frac, face_quality, pet_count, sharpness,
                clip_high_r, clip_high_g, clip_high_b, clip_low, noise_sigma
            FROM photo_traits WHERE file_id = ?
            """, arguments: [fileID, donorID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO places SELECT ?, geocoded_hash, dataset_version,
                city, admin, country, place_key
            FROM places WHERE file_id = ?
            """, arguments: [fileID, donorID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO embeddings SELECT ?, vector, model_version, updated_at
            FROM embeddings WHERE file_id = ?
            """, arguments: [fileID, donorID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO clip_embeddings SELECT ?, embedded_hash, model_generation, vector
            FROM clip_embeddings WHERE file_id = ?
            """, arguments: [fileID, donorID])

        // OCR text and caption are content-derived and come across; the
        // BASENAME does not — this copy keeps the name it has on disk, which is
        // the whole reason it is searchable by that name.
        try db.execute(sql: """
            UPDATE files_fts SET
                ocr_text = (SELECT ocr_text FROM files_fts WHERE file_id = ?),
                caption = (SELECT caption FROM files_fts WHERE file_id = ?)
            WHERE file_id = ?
            """, arguments: [donorID, donorID, fileID])

        // VISION tags only, into this copy's own folder scope. Manual tags are
        // the user's per-file business and are never copied by an analysis
        // pass. INSERT OR IGNORE means a label the user already applied here
        // by hand survives — manual beats vision (Q32).
        if let targetDir {
            try db.execute(sql: """
                INSERT OR IGNORE INTO tags (id, file_id, parent_dir, label, source,
                                            confidence, model_version)
                SELECT lower(hex(randomblob(16))), ?, ?, label, source, confidence, model_version
                FROM tags WHERE file_id = ? AND source <> 'manual'
                """, arguments: [fileID, targetDir, donorID])
        }

        return true
    }
}
