//
//  PhotoStatsQueries.swift
//  Muse
//
//  One read joining `photo_meta` + `photo_traits` into `PhotoFeedback.Inputs`.
//
//  A pure nonisolated query enum (the `NoteStore` shape), called inside passes
//  that are already off-main. Both rows are optional: a photo with EXIF but no
//  traits yet still deserves the notes its EXIF supports, and absent fields
//  simply never fire a rule.
//

import GRDB

nonisolated enum PhotoStatsQueries {

    static func feedbackInputs(fileID: String, db: GRDB.Database) throws -> PhotoFeedback.Inputs? {
        let meta = try Row.fetchOne(db, sql: """
            SELECT iso, exposure_seconds, f_number, focal_length_35mm, flash_fired
            FROM photo_meta WHERE file_id = ?
            """, arguments: [fileID])
        let traits = try Row.fetchOne(db, sql: """
            SELECT face_count, sharpness, clip_high_r, clip_high_g, clip_high_b,
                   clip_low, noise_sigma
            FROM photo_traits WHERE file_id = ?
            """, arguments: [fileID])

        // No rows at all means we know nothing about this photo — which is not
        // the same as knowing it's fine, so return nil and render no card.
        guard meta != nil || traits != nil else { return nil }

        let focal35: Int? = meta?["focal_length_35mm"]
        let flash: Bool? = meta?["flash_fired"]
        return PhotoFeedback.Inputs(
            iso: meta?["iso"],
            exposureSeconds: meta?["exposure_seconds"],
            fNumber: meta?["f_number"],
            focalLength35: focal35.map(Double.init),
            flashFired: flash,
            sharpness: traits?["sharpness"],
            faceCount: traits?["face_count"],
            clipHighR: traits?["clip_high_r"],
            clipHighG: traits?["clip_high_g"],
            clipHighB: traits?["clip_high_b"],
            clipLow: traits?["clip_low"],
            noiseSigma: traits?["noise_sigma"])
    }

    /// Path-keyed convenience for callers that have a URL rather than a file id
    /// (the editor). The feedback data is all content-derived, so resolving
    /// through the alive path is enough — no `parent_dir` scoping needed.
    static func feedbackInputs(path: String, db: GRDB.Database) throws -> PhotoFeedback.Inputs? {
        guard let fileID = try String.fetchOne(db, sql: """
            SELECT file_id FROM paths WHERE absolute_path = ? AND is_alive = 1 LIMIT 1
            """, arguments: [path])
        else { return nil }
        return try feedbackInputs(fileID: fileID, db: db)
    }
}
