//
//  TagStore.swift
//  Muse
//
//  Read/write helpers for the tags table. Tag uniqueness is enforced at
//  the schema level (UNIQUE(file_id, label)). Manual beats Vision on
//  conflict per Q32.
//

import Foundation
import GRDB

@MainActor
final class TagStore: ObservableObject {
    static let shared = TagStore()
    private init() {}

    /// Fetch tags for a file URL. Returns [] if the file isn't indexed yet.
    func tags(for url: URL) async -> [TagRow] {
        guard let queue = Database.shared.dbQueue else { return [] }
        let absPath = url.standardizedFileURL.path
        return ((try? await queue.read { db -> [TagRow] in
            guard let path = try PathRow
                    .filter(PathRow.Columns.absolute_path == absPath)
                    .filter(PathRow.Columns.is_alive == 1)
                    .fetchOne(db),
                  let fileID = path.file_id else { return [] }
            return try TagRow
                .filter(TagRow.Columns.file_id == fileID)
                .order(TagRow.Columns.label)
                .fetchAll(db)
        }) ?? [])
    }

    func addManualTag(label: String, for url: URL) async -> [TagRow] {
        guard let queue = Database.shared.dbQueue else { return [] }
        let absPath = url.standardizedFileURL.path
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return await tags(for: url) }
        do {
            try await queue.write { db in
                guard let path = try PathRow
                        .filter(PathRow.Columns.absolute_path == absPath)
                        .filter(PathRow.Columns.is_alive == 1)
                        .fetchOne(db),
                      let fileID = path.file_id else { return }

                if let existing = try TagRow
                    .filter(TagRow.Columns.file_id == fileID)
                    .filter(TagRow.Columns.label == trimmed)
                    .fetchOne(db) {
                    var updated = existing
                    updated.source = "manual"
                    updated.confidence = nil
                    try updated.update(db)
                } else {
                    var t = TagRow(
                        id: UUID().uuidString,
                        file_id: fileID,
                        label: trimmed,
                        source: "manual",
                        confidence: nil,
                        model_version: nil
                    )
                    try t.insert(db)
                }
            }
        } catch {
            print("[TagStore] addManualTag failed: \(error)")
        }
        return await tags(for: url)
    }

    /// Renames a label across the whole library. Files already carrying
    /// the new label keep their existing row; the old rows are dropped
    /// (UNIQUE(file_id, label) makes the conflicting UPDATEs no-ops).
    func renameLabel(from old: String, to new: String) async {
        guard let queue = Database.shared.dbQueue else { return }
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old else { return }
        do {
            try await queue.write { db in
                try db.execute(sql: "UPDATE OR IGNORE tags SET label = ? WHERE label = ?",
                               arguments: [trimmed, old])
                try db.execute(sql: "DELETE FROM tags WHERE label = ?",
                               arguments: [old])
            }
        } catch {
            print("[TagStore] renameLabel failed: \(error)")
        }
    }

    /// Removes a label from every file in the library.
    func deleteLabel(_ label: String) async {
        guard let queue = Database.shared.dbQueue else { return }
        do {
            try await queue.write { db in
                try db.execute(sql: "DELETE FROM tags WHERE label = ?",
                               arguments: [label])
            }
        } catch {
            print("[TagStore] deleteLabel failed: \(error)")
        }
    }

    func removeTag(_ tag: TagRow, for url: URL) async -> [TagRow] {
        guard let queue = Database.shared.dbQueue else { return [] }
        let tagID = tag.id
        do {
            try await queue.write { db in
                _ = try TagRow.filter(Column("id") == tagID).deleteAll(db)
            }
        } catch {
            print("[TagStore] removeTag failed: \(error)")
        }
        return await tags(for: url)
    }
}
