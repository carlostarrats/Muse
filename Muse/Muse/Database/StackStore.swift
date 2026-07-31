//
//  StackStore.swift
//  Muse
//
//  Pure db-taking functions (the NoteStore/PlaceQueries shape). Stacks are
//  PRESENTATION-ONLY, content-keyed sets of file_id — no parent_dir, no path.
//  Stacking writes only `stacks`/`stack_members`; tags, ratings, notes,
//  collection memberships, paths and analyzed_hash are never touched.
//
//  `dissolved` is a permanent tombstone (the collection setHidden pattern):
//  unstacking keeps the row AND its members so the auto-stacker never re-forms
//  it. `claimedFileIDs` therefore includes dissolved-stack members on purpose —
//  that is what makes "off-limits to the auto-stacker, forever" durable. Don't
//  "clean up" dissolved rows.
//

import Foundation
import GRDB

nonisolated struct StackRef: Equatable, Sendable {
    let stackID: String
    let kind: String
    let dissolved: Bool
    let pickFileID: String?
}

nonisolated enum StackStore {
    /// SQLite's default parameter ceiling is 999; 800 leaves headroom.
    static let idChunk = 800

    static func stacksFor(fileIDs: [String], db: GRDB.Database) throws -> [String: StackRef] {
        guard !fileIDs.isEmpty else { return [:] }
        var result: [String: StackRef] = [:]
        var index = 0
        while index < fileIDs.count {
            let end = min(index + idChunk, fileIDs.count)
            let chunk = Array(fileIDs[index..<end])
            index = end
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT sm.file_id AS file_id, s.id AS stack_id, s.kind AS kind,
                       s.dissolved AS dissolved, s.pick_file_id AS pick_file_id
                FROM stack_members sm JOIN stacks s ON s.id = sm.stack_id
                WHERE sm.file_id IN (\(placeholders))
                """, arguments: StatementArguments(chunk))
            for row in rows {
                guard let fileID: String = row["file_id"], let stackID: String = row["stack_id"],
                      let kind: String = row["kind"] else { continue }
                result[fileID] = StackRef(stackID: stackID, kind: kind,
                                          dissolved: row["dissolved"] ?? false,
                                          pickFileID: row["pick_file_id"])
            }
        }
        return result
    }

    /// Every file with ANY `stack_members` row, dissolved included — the
    /// auto-stacker's "virgin files only" boundary.
    static func claimedFileIDs(db: GRDB.Database) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT file_id FROM stack_members")
        return Set(rows.compactMap { $0["file_id"] as String? })
    }

    @discardableResult
    static func createStack(kind: String, memberIDs: [String], pick: String?,
                            db: GRDB.Database) throws -> String {
        let id = UUID().uuidString
        var stack = StackRow(id: id, kind: kind, dissolved: false, pick_file_id: pick,
                             created_at: Int64(Date().timeIntervalSince1970))
        try stack.insert(db)
        for memberID in memberIDs {
            var member = StackMemberRow(stack_id: id, file_id: memberID)
            try member.insert(db)
        }
        return id
    }

    static func dissolve(stackID: String, db: GRDB.Database) throws {
        try db.execute(sql: "UPDATE stacks SET dissolved = 1 WHERE id = ?", arguments: [stackID])
    }

    static func setPick(stackID: String, fileID: String?, db: GRDB.Database) throws {
        try db.execute(sql: "UPDATE stacks SET pick_file_id = ? WHERE id = ?",
                       arguments: [fileID, stackID])
    }

    /// Removing a member below 2 remaining dissolves the stack — a one-member
    /// "stack" is not a stack.
    static func removeMember(stackID: String, fileID: String, db: GRDB.Database) throws {
        try db.execute(sql: "DELETE FROM stack_members WHERE stack_id = ? AND file_id = ?",
                       arguments: [stackID, fileID])
        let remaining = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM stack_members WHERE stack_id = ?",
            arguments: [stackID]) ?? 0
        if remaining < 2 { try dissolve(stackID: stackID, db: db) }
    }
}
