//
//  InheritDonor.swift
//  Muse
//
//  Which existing copy a NEW copy inherits from.
//
//  Under per-file identity a new path whose bytes match an existing file is a
//  COPY, not another name for the same photo — it gets its own `files` row.
//  The question this answers is what that row starts life carrying.
//
//  Owner decision (2026-08-03): it inherits. "There will be some cases of a
//  user wanting to try two different edits to duplicate images to see the
//  differences" — so duplicating a photo that already carries edits should
//  start from those edits and diverge, not from blank.
//
//  Pure, so the rule is testable without a database. The ordering is TOTAL:
//  same folder, then most recently edited, then lowest path. Without the final
//  tie-break the same duplicate would inherit differently depending on the
//  order SQLite happened to return rows in.
//

import Foundation

nonisolated enum InheritDonor {

    struct Candidate: Equatable, Sendable {
        var fileID: String
        var parentDir: String
        var absolutePath: String
        /// `edits.updated_at`, or nil when this copy carries no edit.
        var editUpdatedAt: Int64?
    }

    /// The `file_id` to inherit from, or nil when there is nothing to inherit.
    static func pick(candidates: [Candidate], targetDir: String) -> String? {
        candidates.min { lhs, rhs in
            // 1. A copy in the same folder — "I duplicated the one I was just
            //    working on" — beats anything elsewhere, however recent.
            let lSame = lhs.parentDir == targetDir
            let rSame = rhs.parentDir == targetDir
            if lSame != rSame { return lSame }
            // 2. Most recently edited. An unedited copy sorts last rather than
            //    first, so an edited copy is always preferred as a donor.
            let lEdit = lhs.editUpdatedAt ?? .min
            let rEdit = rhs.editUpdatedAt ?? .min
            if lEdit != rEdit { return lEdit > rEdit }
            // 3. Lowest path, purely so the result is deterministic.
            return lhs.absolutePath < rhs.absolutePath
        }?.fileID
    }
}
