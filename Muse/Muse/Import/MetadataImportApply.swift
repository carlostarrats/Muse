//
//  MetadataImportApply.swift
//  Muse
//
//  The DB half of the keywords & ratings import: pure-SQL statics testable
//  on an in-memory queue (pattern: Indexer.inheritVisionTags). Insert-or-
//  promote mirrors TagStore.addManualTag exactly — manual tier so the
//  auto-tagger can never undo the imported tags (Q32), scoped per
//  (file_id, parent_dir) like every tag write.
//

import Foundation
import GRDB

enum MetadataImportApply {

    struct Scope {
        let fileID: String
        let dir: String
    }

    /// The tag scope for an ALIVE indexed path — nil when the file isn't in
    /// the index (the import counts it skipped rather than writing tags that
    /// would land nowhere).
    static func scope(db: GRDB.Database, absPath: String) throws -> Scope? {
        guard let path = try PathRow
                .filter(PathRow.Columns.absolute_path == absPath)
                .filter(PathRow.Columns.is_alive == 1)
                .fetchOne(db),
              let fileID = path.file_id else { return nil }
        return Scope(fileID: fileID, dir: TagScope.parentDir(ofPath: absPath))
    }

    /// Insert each label as a MANUAL tag, or promote an existing row (vision
    /// or manual) to manual — the same branch TagStore.addManualTag uses, so
    /// re-importing (or importing over hand-typed tags) is a no-op.
    static func applyKeywords(db: GRDB.Database, scope: Scope, labels: [String]) throws {
        for label in labels {
            if let existing = try TagRow
                .filter(TagRow.Columns.file_id == scope.fileID)
                .filter(TagRow.Columns.parent_dir == scope.dir)
                .filter(TagRow.Columns.label == label)
                .fetchOne(db) {
                var updated = existing
                updated.source = "manual"
                updated.confidence = nil
                try updated.update(db)
            } else {
                var row = TagRow(
                    id: UUID().uuidString,
                    file_id: scope.fileID,
                    parent_dir: scope.dir,
                    label: label,
                    source: "manual",
                    confidence: nil,
                    model_version: nil
                )
                try row.insert(db)
            }
        }
    }

    /// Whether the file already carries a Muse star rating in this folder
    /// scope — the import never overwrites one (rating fills gaps only).
    static func hasRating(db: GRDB.Database, scope: Scope) throws -> Bool {
        let labels = try String.fetchAll(db, sql:
            "SELECT label FROM tags WHERE file_id = ? AND parent_dir = ?",
            arguments: [scope.fileID, scope.dir])
        return labels.contains(where: StarRating.isRating)
    }
}
