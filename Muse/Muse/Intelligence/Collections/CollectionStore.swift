//
//  CollectionStore.swift
//  Muse
//
//  DB CRUD for AI-generated collections. Upserts replace membership
//  wholesale; hidden collections are excluded from fetchAll.
//

import Foundation
import GRDB

/// Default naming for hand-made collections: "Collection 1", "Collection 2", …
/// The next number is one past the highest existing "Collection N" (across all
/// collections, so numbers never collide), with gaps ignored.
enum ManualCollectionName {
    static let prefix = "Collection "

    static func next(existing names: [String]) -> String {
        let maxN = names.compactMap(number(in:)).max() ?? 0
        return "\(prefix)\(maxN + 1)"
    }

    /// The N in "Collection N", or nil if the name isn't of that exact form.
    static func number(in name: String) -> Int? {
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = name.dropFirst(prefix.count)
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        return Int(suffix)
    }
}

enum CollectionStore {
    struct Loaded {
        var collection: CollectionRow
        var memberIDs: [String]
        /// Members with an alive path — what the user actually has on disk.
        /// Cards, headers, and the row all display THIS, so deleting images
        /// or removing folders auto-shrinks (and at zero, hides) a collection.
        var aliveCount: Int
        /// User-chosen cover file id; nil = auto (first alive member).
        var coverFileID: String?
    }

    /// Next bottom slot for a new collection (max existing + 1; 0 if empty).
    static func nextSortOrder(_ db: GRDB.Database) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM collections") ?? -1) + 1
    }

    /// Write sort_order = index for each id, in one transaction. The sidebar
    /// computes the final order (drag / Move Up-Down) and calls this. Used only
    /// by the sidebar's COLLECTIONS section; the Collections page is unaffected.
    static func persistOrder(queue: DatabaseQueue, orderedIDs: [String]) async throws {
        try await queue.write { db in
            for (i, id) in orderedIDs.enumerated() {
                try db.execute(sql: "UPDATE collections SET sort_order = ? WHERE id = ?",
                               arguments: [i, id])
            }
        }
    }

    static func upsert(queue: DatabaseQueue, id: String, name: String,
                       memberIDs: [String], modelVersion: String) async throws {
        let now = Int64(Date().timeIntervalSince1970)
        try await queue.write { db in
            // New auto collections append at the bottom; the ON CONFLICT path
            // deliberately leaves sort_order untouched so a user's manual
            // arrangement survives reclustering.
            let order = try nextSortOrder(db)
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order)
                VALUES (?, ?, 0, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name,
                    model_version = excluded.model_version, updated_at = excluded.updated_at
                """, arguments: [id, name, modelVersion, now, now, order])
            // Only auto members are rebuilt; manual adds survive reclustering.
            try db.execute(sql: """
                DELETE FROM collection_members WHERE collection_id = ? AND added_by = 'auto'
                """, arguments: [id])
            let excluded = try Set(String.fetchAll(db, sql:
                "SELECT file_id FROM collection_exclusions WHERE collection_id = ?",
                arguments: [id]))
            for fid in memberIDs where !excluded.contains(fid) {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO collection_members (collection_id, file_id, added_by)
                    VALUES (?, ?, 'auto')
                    """, arguments: [id, fid])
            }
        }
    }

    /// Manually add a file to a collection. Clears any standing exclusion.
    static func addFile(queue: DatabaseQueue, fileID: String, collectionID: String) async throws {
        try await queue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO collection_members (collection_id, file_id, added_by)
                VALUES (?, ?, 'manual')
                """, arguments: [collectionID, fileID])
            try db.execute(sql: "DELETE FROM collection_exclusions WHERE collection_id = ? AND file_id = ?",
                           arguments: [collectionID, fileID])
        }
    }

    /// Resolve standardized absolute paths to their (alive) file_ids.
    static func fileIDs(queue: DatabaseQueue, paths: [String]) async throws -> [String] {
        guard !paths.isEmpty else { return [] }
        return try await queue.read { db in
            let placeholders = paths.map { _ in "?" }.joined(separator: ",")
            let rows = try PathRow.fetchAll(
                db,
                sql: "SELECT * FROM paths WHERE absolute_path IN (\(placeholders)) AND is_alive = 1",
                arguments: StatementArguments(paths))
            return rows.compactMap { $0.file_id }
        }
    }

    /// Manually remove a file from a collection. Records an exclusion so
    /// future auto rebuilds cannot re-add it.
    static func removeFile(queue: DatabaseQueue, fileID: String, collectionID: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM collection_members WHERE collection_id = ? AND file_id = ?",
                           arguments: [collectionID, fileID])
            try db.execute(sql: """
                INSERT OR IGNORE INTO collection_exclusions (collection_id, file_id) VALUES (?, ?)
                """, arguments: [collectionID, fileID])
        }
    }

    /// Visible collections containing a given file.
    static func collections(queue: DatabaseQueue, forFileID fileID: String) async throws -> [CollectionRow] {
        try await queue.read { db in
            try CollectionRow.fetchAll(db, sql: """
                SELECT c.* FROM collections c
                JOIN collection_members m ON m.collection_id = c.id
                WHERE m.file_id = ? AND c.is_hidden = 0
                """, arguments: [fileID])
        }
    }

    /// Create a brand-new manual collection containing one file.
    static func createManual(queue: DatabaseQueue, name: String, fileID: String) async throws -> String {
        let id = UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970)
        try await queue.write { db in
            let order = try nextSortOrder(db)
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order)
                VALUES (?, ?, 0, 'manual', ?, ?, ?)
                """, arguments: [id, name, now, now, order])
            try db.execute(sql: """
                INSERT INTO collection_members (collection_id, file_id, added_by) VALUES (?, ?, 'manual')
                """, arguments: [id, fileID])
        }
        return id
    }

    /// Collections that must never be deleted as stale by the engine:
    /// manual model_version OR any manual members.
    static func protectedCollectionIDs(queue: DatabaseQueue) async throws -> Set<String> {
        try await queue.read { db in
            var ids = try Set(String.fetchAll(db, sql:
                "SELECT id FROM collections WHERE model_version = 'manual'"))
            ids.formUnion(try String.fetchAll(db, sql:
                "SELECT DISTINCT collection_id FROM collection_members WHERE added_by = 'manual'"))
            return ids
        }
    }

    static func rename(queue: DatabaseQueue, id: String, name: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "UPDATE collections SET name = ? WHERE id = ?",
                           arguments: [name, id])
        }
    }

    /// Create an empty, hand-made collection auto-named "Collection N".
    /// Marked model_version = 'manual' so the auto-organizer never reclusters
    /// or prunes it (it's protected + shown even while empty). Returns its id.
    /// Name choice + insert happen in one write so concurrent adds can't collide.
    @discardableResult
    static func createManual(queue: DatabaseQueue) async throws -> String {
        let id = UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970)
        try await queue.write { db in
            let names = try String.fetchAll(db, sql: "SELECT name FROM collections")
            let name = ManualCollectionName.next(existing: names)
            let order = try nextSortOrder(db)
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order)
                VALUES (?, ?, 0, 'manual', ?, ?, ?)
                """, arguments: [id, name, now, now, order])
        }
        return id
    }

    /// Create a smart collection: a manual-marked row (so the reclusterer never
    /// prunes it and it stays visible even when its rules match nothing) whose
    /// membership is defined by `ruleSet`, held as JSON in smart_rules. No member
    /// rows — membership resolves live.
    @discardableResult
    static func createSmart(queue: DatabaseQueue, name: String, ruleSet: SmartRuleSet) async throws -> String {
        let id = UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970)
        let json = ruleSet.encodedJSON()
        try await queue.write { db in
            let order = try nextSortOrder(db)
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order, smart_rules)
                VALUES (?, ?, 0, 'manual', ?, ?, ?, ?)
                """, arguments: [id, name, now, now, order, json])
        }
        return id
    }

    /// Replace a smart collection's rules (and optionally its name).
    static func setSmartRules(queue: DatabaseQueue, id: String, name: String?,
                              ruleSet: SmartRuleSet) async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let json = ruleSet.encodedJSON()
        try await queue.write { db in
            if let name {
                try db.execute(sql: "UPDATE collections SET name = ?, smart_rules = ?, updated_at = ? WHERE id = ?",
                               arguments: [name, json, now, id])
            } else {
                try db.execute(sql: "UPDATE collections SET smart_rules = ?, updated_at = ? WHERE id = ?",
                               arguments: [json, now, id])
            }
        }
    }

    /// Convert an existing (manual/auto) collection into a smart one: set its
    /// rules, force model_version = 'manual' (protection + empty-visibility), and
    /// drop its hand-picked members (they're replaced by rule-based membership).
    static func makeSmart(queue: DatabaseQueue, id: String, ruleSet: SmartRuleSet) async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let json = ruleSet.encodedJSON()
        try await queue.write { db in
            try db.execute(sql: """
                UPDATE collections SET smart_rules = ?, model_version = 'manual', updated_at = ? WHERE id = ?
                """, arguments: [json, now, id])
            try db.execute(sql: "DELETE FROM collection_members WHERE collection_id = ?", arguments: [id])
        }
    }

    /// Decoded rule set for a smart collection, or nil if the row isn't smart.
    static func smartRuleSet(queue: DatabaseQueue, id: String) async throws -> SmartRuleSet? {
        try await queue.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT smart_rules FROM collections WHERE id = ?",
                                                 arguments: [id]) else { return nil }
            return SmartRuleSet.decode(json)
        }
    }

    /// Alive absolute paths for ANY collection — resolving smart collections via
    /// their rules and reading member rows for the rest. The single seam so
    /// setActiveCollection / exportableURLs / cover mosaics stay collection-kind
    /// agnostic. `limit` caps the returned paths (cover thumbnails).
    static func alivePathsResolving(queue: DatabaseQueue, collectionID: String,
                                    limit: Int? = nil) async throws -> [String] {
        if let set = try await smartRuleSet(queue: queue, id: collectionID) {
            let paths = try await queue.read { db in
                try SmartCollectionResolver.alivePaths(set, db: db)
            }
            if let limit { return Array(paths.prefix(limit)) }
            return paths
        }
        return try await alivePaths(queue: queue, collectionID: collectionID, limit: limit)
    }

    // NOTE: there is intentionally no hard-delete. Collections are auto-
    // generated, so a row-delete silently regenerates on the next analyze.
    // Deletion goes through setHidden(true) (the durable "don't rebuild"
    // tombstone) — see ActiveCollectionHeader/CollectionCard.deleteCollection.

    /// Set (or replace) a collection's chosen cover image. One per collection.
    static func setCover(queue: DatabaseQueue, id: String, fileID: String) async throws {
        let now = Int64(Date().timeIntervalSince1970)
        try await queue.write { db in
            try db.execute(sql: "UPDATE collections SET cover_file_id = ?, updated_at = ? WHERE id = ?",
                           arguments: [fileID, now, id])
        }
    }

    /// Set (or clear) a collection's sidebar appearance. `icon` is an SF
    /// Symbol name, `color` a CollectionAppearance token; nil/nil restores
    /// the default look. Same shape as setCover.
    static func setAppearance(queue: DatabaseQueue, id: String,
                              icon: String?, color: String?) async throws {
        let now = Int64(Date().timeIntervalSince1970)
        try await queue.write { db in
            try db.execute(sql: "UPDATE collections SET icon = ?, color = ?, updated_at = ? WHERE id = ?",
                           arguments: [icon, color, now, id])
        }
    }

    /// Resolve an alive file's absolute path to its file id (nil if not indexed
    /// / not alive). Mirrors the lookup TagStore uses.
    static func fileID(queue: DatabaseQueue, path: String) async throws -> String? {
        try await queue.read { db in
            try PathRow
                .filter(PathRow.Columns.absolute_path == path)
                .filter(PathRow.Columns.is_alive == 1)
                .fetchOne(db)?
                .file_id
        }
    }

    /// The chosen cover's alive absolute path — but only if it's still an alive
    /// member of the collection. Returns nil otherwise so callers fall back to
    /// the auto cover (first alive member).
    static func coverPath(queue: DatabaseQueue, collectionID: String,
                          coverFileID: String) async throws -> String? {
        try await queue.read { db in
            try String.fetchOne(db, sql: """
                SELECT p.absolute_path FROM paths p
                JOIN collection_members m ON m.file_id = p.file_id
                WHERE p.is_alive = 1 AND p.file_id = ? AND m.collection_id = ?
                LIMIT 1
                """, arguments: [coverFileID, collectionID])
        }
    }

    static func setHidden(queue: DatabaseQueue, id: String, hidden: Bool) async throws {
        try await queue.write { db in
            try db.execute(sql: "UPDATE collections SET is_hidden = ? WHERE id = ?",
                           arguments: [hidden ? 1 : 0, id])
        }
    }

    /// True if `path` is one of `roots` or lies beneath one — a pure prefix rule
    /// with no disk access. "/a/Inspo" matches "/a/Inspo" and "/a/Inspo/x.jpg"
    /// but NOT the sibling "/a/Inspo Extra/x.jpg". Empty roots match nothing.
    static func isUnderAnyRoot(_ path: String, roots: [String]) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// `rootPaths` = standardized active root paths. When non-empty, `aliveCount`
    /// counts only members the grid could actually show — alive AND under a root —
    /// so the badge can never claim a number the opened grid can't back up, and an
    /// out-of-root file (e.g. ~/Downloads/social.jpg, unshowable by the sandbox)
    /// stops inflating the count. Empty `rootPaths` (before AppState has pushed the
    /// roots) falls back to the plain alive count so nothing zeroes out. See the
    /// 2026-06-19 "shows N but opens empty" fix (Lever 1).
    static func fetchAll(queue: DatabaseQueue, rootPaths: [String] = []) async throws -> [Loaded] {
        try await queue.read { db in
            let rows = try CollectionRow
                .filter(Column("is_hidden") == 0)
                .fetchAll(db)
            return try rows.map { row in
                // Smart collections hold no member rows — resolve alive paths from
                // their rules. Everything else reads collection_members as before.
                let members: [String]
                let alivePaths: [String]
                if let json = row.smart_rules, let set = SmartRuleSet.decode(json) {
                    alivePaths = try SmartCollectionResolver.alivePaths(set, db: db)
                    members = Array(try SmartCollectionResolver.memberIDs(set, db: db))
                } else {
                    members = try String.fetchAll(db, sql:
                        "SELECT file_id FROM collection_members WHERE collection_id = ?",
                        arguments: [row.id])
                    // Count alive member PATHS (what the grid renders per-path), then
                    // narrow to those under an active root when the roots are known.
                    alivePaths = try String.fetchAll(db, sql: """
                        SELECT DISTINCT p.absolute_path FROM paths p
                        JOIN collection_members m ON m.file_id = p.file_id
                        WHERE m.collection_id = ? AND p.is_alive = 1
                        """, arguments: [row.id])
                }
                let alive = rootPaths.isEmpty
                    ? alivePaths.count
                    : alivePaths.filter { isUnderAnyRoot($0, roots: rootPaths) }.count
                return Loaded(collection: row, memberIDs: members, aliveCount: alive,
                              coverFileID: row.cover_file_id)
            }
            // Auto collections with nothing on disk are hidden; hand-made
            // ('manual') collections stay visible even while empty, so a just-
            // created one shows up and can be populated.
            .filter { $0.aliveCount > 0 || $0.collection.model_version == "manual" }
            .sorted { $0.aliveCount > $1.aliveCount }          // biggest first
        }
    }

    /// How many alive files sit under the current roots — i.e. images the grid
    /// could actually show anywhere in the library. Drives the "no images → no
    /// Collections UI" gate (the collection rows themselves are content, so an
    /// empty library must show none, not even empty hand-made ones). Uses the same
    /// `isUnderAnyRoot` recursive-prefix rule as the count so "reachable" means the
    /// same thing in both places. Returns -1 when `rootPaths` is empty (roots not
    /// yet pushed at launch) so the caller can treat it as "unknown → don't hide"
    /// and avoid flickering collections away during the launch race.
    static func reachableFileCount(queue: DatabaseQueue, rootPaths: [String]) async throws -> Int {
        guard !rootPaths.isEmpty else { return -1 }
        return try await queue.read { db in
            var clauses: [String] = []
            var args: [DatabaseValueConvertible] = []
            for root in rootPaths {
                let prefix = root + "/"
                clauses.append("(absolute_path = ? OR SUBSTR(absolute_path, 1, LENGTH(?)) = ?)")
                args.append(root); args.append(prefix); args.append(prefix)
            }
            let sql = "SELECT COUNT(*) FROM paths WHERE is_alive = 1 AND ("
                + clauses.joined(separator: " OR ") + ")"
            return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
        }
    }

    /// Alive absolute paths for a collection's members (for mosaics and
    /// grid filtering). Optional limit for cover thumbnails.
    static func alivePaths(queue: DatabaseQueue, collectionID: String,
                           limit: Int? = nil) async throws -> [String] {
        try await queue.read { db in
            var sql = """
                SELECT absolute_path FROM paths
                WHERE is_alive = 1 AND file_id IN
                    (SELECT file_id FROM collection_members WHERE collection_id = ?)
                """
            if let limit { sql += " LIMIT \(limit)" }
            return try String.fetchAll(db, sql: sql, arguments: [collectionID])
        }
    }

    /// Old state for identity matching: id -> member set
    static func currentMembership(queue: DatabaseQueue) async throws -> [String: Set<String>] {
        try await queue.read { db in
            var out: [String: Set<String>] = [:]
            let rows = try Row.fetchAll(db, sql:
                "SELECT collection_id, file_id FROM collection_members")
            for r in rows {
                out[r["collection_id"], default: []].insert(r["file_id"])
            }
            return out
        }
    }
}
