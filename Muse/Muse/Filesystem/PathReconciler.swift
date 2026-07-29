//
//  PathReconciler.swift
//  Muse
//
//  Reconciles the index against the filesystem: marks DB path rows DEAD when
//  the file they point at has vanished from disk (deleted or moved out of the
//  folder externally). Without this, a removed file's `is_alive = 1` row
//  lingers forever — leaking into search as a blank, unrenderable tile and
//  inflating collection counts. The normal grid hides this (it enumerates the
//  disk); search + collection counts query the DB by `is_alive`, so the ghost
//  rows surface there.
//
//  Driven per-folder on a fresh selection — the off-main folder load already
//  enumerates the folder, so the "present" set is free. Self-heals as the user
//  browses; no library-wide sweep, no data migration.
//

import Foundation
import GRDB

nonisolated enum PathReconciler {

    // MARK: - Pure scope + diff (unit-tested)

    /// Of `alivePaths`, the ones belonging to `folder` at the current depth:
    /// recursive → anywhere beneath it; non-recursive → direct children only.
    /// Standardized-path in, standardized-path out. Mirrors FolderEventFilter's
    /// scope rule so "what the grid shows" and "what we reconcile" agree.
    static func inScope(_ alivePaths: [String], folder: String,
                        recursive: Bool) -> [String] {
        let prefix = folder + "/"
        return alivePaths.filter { path in
            guard path.hasPrefix(prefix) else { return false }
            if recursive { return true }
            let relative = path.dropFirst(prefix.count)
            return !relative.contains("/")    // direct child only
        }
    }

    /// In-scope alive paths whose file is no longer in the enumerated set.
    static func vanished(inScope: [String], present: Set<String>) -> [String] {
        inScope.filter { !present.contains($0) }
    }

    /// Drop every candidate living under a directory the enumeration could NOT
    /// read. `present` is only evidence of absence where the walk actually
    /// looked: `FileManager.enumerator` with a nil error handler skips an
    /// unreadable subtree SILENTLY (verified — a chmod-000 subfolder yields the
    /// directory itself and none of its children, with no error surfaced), and
    /// the caller's top-level `trustworthy` probe only proves the ROOT is
    /// listable. So in recursive mode a single unreadable/not-yet-materialized
    /// subfolder used to flip every DB row beneath it to `is_alive = 0` — the
    /// mass-false-deletion class `reconcileByExistence`'s `rootReachable` gate
    /// and `Housekeeping.pruneUnreachable`'s root check both exist to prevent,
    /// and worse here because those rows can then be permanently pruned along
    /// with their tags and notes.
    ///
    /// Trailing-slash bounded like every other prefix test in the codebase, so
    /// an unreadable `/a/Inspo` never protects `/a/Inspo Extra/x.jpg`.
    static func excludingProtected(_ paths: [String], protectedDirs: [String]) -> [String] {
        guard !protectedDirs.isEmpty else { return paths }
        let prefixes = protectedDirs.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        return paths.filter { path in !prefixes.contains { path.hasPrefix($0) } }
    }

    // MARK: - Filesystem guard

    /// An OLD-STYLE evicted iCloud file shows a hidden `.<name>.icloud`
    /// placeholder instead of its real name, so the enumeration (which skips
    /// hidden files) won't list it — but it is NOT gone. Keep such rows alive.
    /// Modern dataless-in-place files keep their real name and ARE enumerated,
    /// so they never reach this guard.
    static func isEvictedPlaceholder(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(name).icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    // MARK: - DB

    /// Every alive path under `folder` (prefix match bounds the read to the
    /// folder's subtree, not the whole library). LENGTH/SUBSTR computed in SQL
    /// so character semantics match (mirrors FolderRenameMigration's approach).
    static func aliveUnder(folder: String, queue: DatabaseQueue) -> [String] {
        let prefix = folder + "/"
        return (try? queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT absolute_path FROM paths
                WHERE is_alive = 1 AND SUBSTR(absolute_path, 1, LENGTH(?)) = ?
                """, arguments: [prefix, prefix])
        }) ?? []
    }

    /// Flip the named alive paths to dead in one write. Returns the number of
    /// rows that were alive (and are now dead) — counted up front so the result
    /// is exact and idempotent without relying on driver change-counts.
    ///
    /// Chunked at 500 bindings to stay under SQLite's `SQLITE_MAX_VARIABLE_NUMBER`
    /// (matches the rest of the codebase) — a large deletion (a whole subfolder's
    /// worth at once) must not blow the variable limit and silently no-op.
    @discardableResult
    static func markDead(_ paths: [String], queue: DatabaseQueue) -> Int {
        guard !paths.isEmpty else { return 0 }
        return (try? queue.write { db -> Int in
            var total = 0
            for start in stride(from: 0, to: paths.count, by: 500) {
                let chunk = Array(paths[start..<min(start + 500, paths.count)])
                let marks = databaseQuestionMarks(count: chunk.count)
                let n = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM paths
                    WHERE is_alive = 1 AND absolute_path IN (\(marks))
                    """, arguments: StatementArguments(chunk)) ?? 0
                if n > 0 {
                    try db.execute(sql: """
                        UPDATE paths SET is_alive = 0
                        WHERE is_alive = 1 AND absolute_path IN (\(marks))
                        """, arguments: StatementArguments(chunk))
                }
                total += n
            }
            return total
        }) ?? 0
    }

    /// Reconcile a root's ENTIRE subtree by confirming each alive row still
    /// exists on disk — regardless of how deep it is. The enumeration-based
    /// `reconcile` above only reaches the *browsed depth* (non-recursive = direct
    /// children), so a file whose containing subfolder was deleted wholesale (e.g.
    /// a removed feature's leftover staging dir) is never in scope and its ghost
    /// `is_alive = 1` row lingers forever — inflating collection counts for a
    /// folder the user can no longer browse into. This pass walks every alive path
    /// under `root` and marks dead the ones that are genuinely gone.
    ///
    /// Per-file existence is DATALESS-SAFE and so avoids the partial-iCloud-
    /// materialization data-loss trap that a recursive enumeration-diff would hit:
    /// a not-yet-downloaded iCloud file still has a filesystem entry
    /// (`fileExists == true`), and an old-style evicted file is caught by
    /// `isEvictedPlaceholder`. Only a file with no entry at all — a real deletion —
    /// is flipped. `exists` is injectable so the diff is unit-testable without disk.
    ///
    /// FAILS CLOSED on an unreachable root. Per-file existence protects the
    /// individual-dataless-file case, but NOT the case where the ROOT itself is
    /// transiently gone — an unplugged external volume, an iCloud container not yet
    /// materialized on a cold launch, a folder renamed under a stale bookmark,
    /// revoked scope. There EVERY child reports `fileExists == false` and the whole
    /// subtree would flip `is_alive = 0` in one write — the exact mass-false-deletion
    /// the enumeration path's `trustworthy` guard exists to prevent, and worse here
    /// because deep files it kills are never revived by normal browsing. So the root
    /// is first proven listable (`rootReachable`); if it can't even be enumerated,
    /// NOTHING is touched and `reachable == false` tells the caller to retry later
    /// rather than record the root as done. A genuinely emptied-but-reachable folder
    /// still reconciles (the listing succeeds; its former children are truly gone).
    /// Both probes are injectable for disk-free unit tests.
    struct ExistenceResult { let reachable: Bool; let cleared: Int }

    static func reconcileByExistence(
        root: URL, queue: DatabaseQueue,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0)
                                     || isEvictedPlaceholder($0) },
        rootReachable: (String) -> Bool = {
            (try? FileManager.default.contentsOfDirectory(atPath: $0)) != nil
        }
    ) -> ExistenceResult {
        let rootPath = root.standardizedFileURL.path
        guard rootReachable(rootPath) else {
            return ExistenceResult(reachable: false, cleared: 0)
        }
        let alive = aliveUnder(folder: rootPath, queue: queue)
        let gone = alive.filter { !exists($0) }
        return ExistenceResult(reachable: true, cleared: markDead(gone, queue: queue))
    }

    /// Full per-folder reconcile. `present` = standardized paths the folder
    /// enumeration found. Returns the number of rows marked dead.
    ///
    /// `unreadableDirs` = directories the enumeration that produced `present`
    /// could not descend into (see `excludingProtected`). Rows beneath them are
    /// left alive: absence from `present` is not evidence of deletion where the
    /// walk never looked. The recursive caller MUST pass these.
    @discardableResult
    static func reconcile(folder: URL, recursive: Bool,
                          present: Set<String>, queue: DatabaseQueue,
                          unreadableDirs: [String] = []) -> Int {
        let folderPath = folder.standardizedFileURL.path
        let alive = aliveUnder(folder: folderPath, queue: queue)
        let scoped = inScope(alive, folder: folderPath, recursive: recursive)
        let gone = excludingProtected(vanished(inScope: scoped, present: present),
                                      protectedDirs: unreadableDirs)
            .filter { !isEvictedPlaceholder($0) }
        return markDead(gone, queue: queue)
    }
}
