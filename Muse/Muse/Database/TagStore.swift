//
//  TagStore.swift
//  Muse
//
//  Read/write helpers for the tags table. A tag belongs to a file IN A
//  FOLDER: identity is (file_id, parent_dir), enforced at the schema level
//  (UNIQUE(file_id, parent_dir, label)). The same content in another folder
//  is a different image with its own tags — deletes never leak across
//  folders. Manual beats Vision on conflict per Q32. See TagScope.
//

import Foundation
import GRDB

/// Resolve standardized absolute paths to their (file_id, parent_dir) tag
/// scopes via alive paths. Free + nonisolated so it can run inside a GRDB
/// write/read closure (which is not actor-isolated).
private func tagScopes(forPaths paths: [String], db: GRDB.Database) throws -> [(fileID: String, dir: String)] {
    guard !paths.isEmpty else { return [] }
    let marks = databaseQuestionMarks(count: paths.count)
    let rows = try Row.fetchAll(db, sql: """
        SELECT file_id, absolute_path FROM paths
        WHERE is_alive = 1 AND file_id IS NOT NULL AND absolute_path IN (\(marks))
    """, arguments: StatementArguments(paths))
    return rows.compactMap { row in
        guard let fid: String = row["file_id"],
              let p: String = row["absolute_path"] else { return nil }
        return (fid, TagScope.parentDir(ofPath: p))
    }
}

@MainActor
final class TagStore: ObservableObject {
    static let shared = TagStore()
    private init() {}

    /// Fetch tags for a file URL. Returns [] if the file isn't indexed yet.
    /// Scoped to this file's folder — a duplicate in another folder has its own.
    func tags(for url: URL) async -> [TagRow] {
        guard let queue = Database.shared.dbQueue else { return [] }
        let absPath = url.standardizedFileURL.path
        let dir = TagScope.parentDir(ofPath: absPath)
        return ((try? await queue.read { db -> [TagRow] in
            guard let path = try PathRow
                    .filter(PathRow.Columns.absolute_path == absPath)
                    .filter(PathRow.Columns.is_alive == 1)
                    .fetchOne(db),
                  let fileID = path.file_id else { return [] }
            return try TagRow
                .filter(TagRow.Columns.file_id == fileID)
                .filter(TagRow.Columns.parent_dir == dir)
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
        let dir = TagScope.parentDir(ofPath: absPath)
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
                    .filter(TagRow.Columns.parent_dir == dir)
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
                        parent_dir: dir,
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

    /// Renames a label across the whole library (spelling change — not a
    /// destructive op, so it stays library-wide). Where a file-in-folder
    /// already carries the target label, the two rows merge — and because
    /// manual beats vision (Q32), the surviving row is manual if EITHER side
    /// was. Conflict is per (file_id, parent_dir): the same label under two
    /// folders are independent rows and don't merge.
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
                        .filter(TagRow.Columns.parent_dir == row.parent_dir)
                        .filter(TagRow.Columns.label == trimmed)
                        .fetchOne(db) {
                        // Conflict in the same (file, folder): promote to manual
                        // if the old row was manual, then drop the redundant row.
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

    /// Delete every tag (manual + vision) for the given file URLs, scoped to
    /// each file's folder — duplicates in OTHER folders keep their tags.
    /// Deliberately does NOT touch analyzed_hash, so the automatic analysis
    /// pipeline will not resurrect these tags on the next index pass — they
    /// only return via an explicit Regenerate. No FTS cleanup needed: tags
    /// aren't stored in files_fts.
    func deleteAllTags(forURLs urls: [URL]) async {
        guard let queue = Database.shared.dbQueue else { return }
        let paths = urls.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }
        do {
            try await queue.write { db in
                for scope in try tagScopes(forPaths: paths, db: db) {
                    try db.execute(sql:
                        "DELETE FROM tags WHERE file_id = ? AND parent_dir = ?",
                        arguments: [scope.fileID, scope.dir])
                }
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

    /// Remove one label (manual OR vision) from the given files, scoped to each
    /// file's folder. Like `deleteAllTags`, it leaves `analyzed_hash` untouched
    /// so the automatic pipeline never resurrects the tag.
    func removeLabel(_ label: String, fromURLs urls: [URL]) async {
        guard let queue = Database.shared.dbQueue else { return }
        let paths = urls.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }
        do {
            try await queue.write { db in
                for scope in try tagScopes(forPaths: paths, db: db) {
                    try db.execute(sql: """
                        DELETE FROM tags
                        WHERE label = ? AND file_id = ? AND parent_dir = ?
                        """, arguments: [label, scope.fileID, scope.dir])
                }
            }
        } catch {
            print("[TagStore] removeLabel failed: \(error)")
        }
    }
}
