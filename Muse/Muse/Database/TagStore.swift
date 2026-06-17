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

    /// All distinct tag labels in use, alphabetical.
    func allLabels() async -> [String] {
        guard let queue = Database.shared.dbQueue else { return [] }
        return (try? await queue.read { db in
            try String.fetchAll(db, sql:
                "SELECT DISTINCT label FROM tags ORDER BY label COLLATE NOCASE")
        }) ?? []
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

    /// Renames a label across the whole library. Where a file already
    /// carries the target label, the two rows merge — and because manual
    /// beats vision (Q32), the surviving row is manual if EITHER side was
    /// manual. (A blind `UPDATE OR IGNORE` + `DELETE` would silently destroy
    /// a manual old-label tag whenever a vision target-label row pre-existed.)
    func renameLabel(from old: String, to new: String) async {
        guard let queue = Database.shared.dbQueue else { return }
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old else { return }
        do {
            try await queue.write { db in
                let oldRows = try TagRow
                    .filter(TagRow.Columns.label == old)
                    .fetchAll(db)
                for row in oldRows {
                    if var existing = try TagRow
                        .filter(TagRow.Columns.file_id == row.file_id)
                        .filter(TagRow.Columns.label == trimmed)
                        .fetchOne(db) {
                        // Conflict: a target-label row already exists for this
                        // file. Promote it to manual if the old row was manual,
                        // then drop the now-redundant old-label row.
                        if row.source == "manual", existing.source != "manual" {
                            existing.source = "manual"
                            existing.confidence = nil
                            try existing.update(db)
                        }
                        try row.delete(db)
                    } else {
                        // No conflict — relabel in place, preserving source.
                        var moved = row
                        moved.label = trimmed
                        try moved.update(db)
                    }
                }
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

    /// Delete every tag (manual + vision) for the given file URLs. Scoped by
    /// resolving each URL to its alive file_id. Deliberately does NOT touch
    /// analyzed_hash, so the automatic analysis pipeline will not resurrect
    /// these tags on the next index pass — they only return via an explicit
    /// Regenerate. No FTS cleanup needed: tags aren't stored in files_fts.
    func deleteAllTags(forURLs urls: [URL]) async {
        guard let queue = Database.shared.dbQueue else { return }
        let paths = urls.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }
        do {
            try await queue.write { db in
                let marks = databaseQuestionMarks(count: paths.count)
                try db.execute(sql: """
                    DELETE FROM tags WHERE file_id IN (
                        SELECT p.file_id FROM paths p
                        WHERE p.is_alive = 1 AND p.absolute_path IN (\(marks))
                    )
                    """, arguments: StatementArguments(paths))
            }
        } catch {
            print("[TagStore] deleteAllTags failed: \(error)")
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

    /// Remove one label (manual OR vision) from the given files. Like
    /// `deleteAllTags`, it leaves `analyzed_hash` untouched so the automatic
    /// pipeline never resurrects the tag — only an explicit re-analysis would.
    func removeLabel(_ label: String, fromURLs urls: [URL]) async {
        guard let queue = Database.shared.dbQueue else { return }
        let paths = urls.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }
        do {
            try await queue.write { db in
                let marks = databaseQuestionMarks(count: paths.count)
                try db.execute(sql: """
                    DELETE FROM tags WHERE label = ? AND file_id IN (
                        SELECT p.file_id FROM paths p
                        WHERE p.is_alive = 1 AND p.absolute_path IN (\(marks))
                    )
                    """, arguments: StatementArguments([label] + paths))
            }
        } catch {
            print("[TagStore] removeLabel failed: \(error)")
        }
    }
}
