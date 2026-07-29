import XCTest
import GRDB
@testable import Muse

/// Pure-logic + DB tests for the ghost-row reconciler. The pure scope/diff
/// helpers need no disk; the DB tests run the real SQL against an in-memory
/// GRDB migrated to the current schema.
final class PathReconcilerTests: XCTestCase {
    private let folder = "/Users/me/Inspo"

    // MARK: - Pure scope

    func testInScopeNonRecursiveDirectChildrenOnly() {
        let alive = ["/Users/me/Inspo/a.jpg",
                     "/Users/me/Inspo/sub/b.jpg",
                     "/Users/me/Other/c.jpg",
                     "/Users/me/Inspo.jpg"]           // sibling, not a child
        XCTAssertEqual(PathReconciler.inScope(alive, folder: folder, recursive: false),
                       ["/Users/me/Inspo/a.jpg"])
    }

    func testInScopeRecursiveKeepsSubtree() {
        let alive = ["/Users/me/Inspo/a.jpg",
                     "/Users/me/Inspo/sub/b.jpg",
                     "/Users/me/Other/c.jpg"]
        XCTAssertEqual(Set(PathReconciler.inScope(alive, folder: folder, recursive: true)),
                       ["/Users/me/Inspo/a.jpg", "/Users/me/Inspo/sub/b.jpg"])
    }

    // MARK: - Pure diff

    func testVanishedReturnsMissingOnly() {
        let scope = ["/Users/me/Inspo/a.jpg", "/Users/me/Inspo/gone.jpg"]
        let present: Set<String> = ["/Users/me/Inspo/a.jpg"]
        XCTAssertEqual(PathReconciler.vanished(inScope: scope, present: present),
                       ["/Users/me/Inspo/gone.jpg"])
    }

    func testVanishedEmptyWhenAllPresent() {
        let scope = ["/Users/me/Inspo/a.jpg"]
        XCTAssertTrue(PathReconciler.vanished(inScope: scope,
                                              present: ["/Users/me/Inspo/a.jpg"]).isEmpty)
    }

    // MARK: - DB helpers

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func insertAlivePath(_ q: DatabaseQueue, _ path: String) throws {
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, bookmark_data, is_alive)
                VALUES (?, NULL, ?, NULL, 1)
                """, arguments: [UUID().uuidString, path])
        }
    }

    private func isAlive(_ q: DatabaseQueue, _ path: String) throws -> Int? {
        try q.read { db in
            try Int.fetchOne(db,
                sql: "SELECT is_alive FROM paths WHERE absolute_path = ?",
                arguments: [path])
        }
    }

    // MARK: - DB ops

    func testMarkDeadFlipsOnlyNamedRows() throws {
        let q = try makeQueue()
        try insertAlivePath(q, "/Users/me/Inspo/a.jpg")
        try insertAlivePath(q, "/Users/me/Inspo/gone.jpg")

        let n = PathReconciler.markDead(["/Users/me/Inspo/gone.jpg"], queue: q)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(try isAlive(q, "/Users/me/Inspo/a.jpg"), 1)
        XCTAssertEqual(try isAlive(q, "/Users/me/Inspo/gone.jpg"), 0)

        // Idempotent: a second pass changes nothing.
        XCTAssertEqual(PathReconciler.markDead(["/Users/me/Inspo/gone.jpg"], queue: q), 0)
    }

    func testReconcileMarksMissingDeadKeepsPresent() throws {
        let q = try makeQueue()
        try insertAlivePath(q, "/Users/me/Inspo/a.jpg")
        try insertAlivePath(q, "/Users/me/Inspo/gone.jpg")
        try insertAlivePath(q, "/Users/me/Other/x.jpg")   // out of scope — untouched

        let n = PathReconciler.reconcile(
            folder: URL(fileURLWithPath: "/Users/me/Inspo"),
            recursive: false,
            present: ["/Users/me/Inspo/a.jpg"],
            queue: q)

        XCTAssertEqual(n, 1)
        XCTAssertEqual(try isAlive(q, "/Users/me/Inspo/a.jpg"), 1)
        XCTAssertEqual(try isAlive(q, "/Users/me/Inspo/gone.jpg"), 0)
        XCTAssertEqual(try isAlive(q, "/Users/me/Other/x.jpg"), 1)
    }

    // MARK: - Unreadable-subfolder protection

    func testExcludingProtectedIsPrefixBoundedBySlash() {
        // A protected `/a/Inspo` must not swallow the sibling `/a/Inspo Extra`.
        let candidates = ["/a/Inspo/x.jpg", "/a/Inspo/sub/y.jpg",
                          "/a/Inspo Extra/z.jpg", "/a/Other/w.jpg"]
        XCTAssertEqual(
            PathReconciler.excludingProtected(candidates, protectedDirs: ["/a/Inspo"]),
            ["/a/Inspo Extra/z.jpg", "/a/Other/w.jpg"])
        // No protection = untouched passthrough.
        XCTAssertEqual(PathReconciler.excludingProtected(candidates, protectedDirs: []),
                       candidates)
    }

    func testRecursiveReconcileKeepsRowsUnderUnreadableSubfolder() throws {
        // The regression: a recursive walk skips an unreadable subfolder in
        // silence, so its files are missing from `present` without being gone.
        // Their rows must stay alive; genuinely-vanished siblings still die.
        let q = try makeQueue()
        try insertAlivePath(q, "/Users/me/Inspo/a.jpg")
        try insertAlivePath(q, "/Users/me/Inspo/locked/b.jpg")
        try insertAlivePath(q, "/Users/me/Inspo/open/gone.jpg")

        let n = PathReconciler.reconcile(
            folder: URL(fileURLWithPath: "/Users/me/Inspo"),
            recursive: true,
            present: ["/Users/me/Inspo/a.jpg"],
            queue: q,
            unreadableDirs: ["/Users/me/Inspo/locked"])

        XCTAssertEqual(n, 1)
        XCTAssertEqual(try isAlive(q, "/Users/me/Inspo/a.jpg"), 1)
        XCTAssertEqual(try isAlive(q, "/Users/me/Inspo/locked/b.jpg"), 1)
        XCTAssertEqual(try isAlive(q, "/Users/me/Inspo/open/gone.jpg"), 0)
    }

    func testRecursiveReconcileWithoutProtectionStillReapsRealDeletions() throws {
        // Guards the fix from over-reaching: with nothing protected the pass
        // behaves exactly as before.
        let q = try makeQueue()
        try insertAlivePath(q, "/Users/me/Inspo/a.jpg")
        try insertAlivePath(q, "/Users/me/Inspo/sub/gone.jpg")

        let n = PathReconciler.reconcile(
            folder: URL(fileURLWithPath: "/Users/me/Inspo"),
            recursive: true,
            present: ["/Users/me/Inspo/a.jpg"],
            queue: q)

        XCTAssertEqual(n, 1)
        XCTAssertEqual(try isAlive(q, "/Users/me/Inspo/sub/gone.jpg"), 0)
    }

    /// End-to-end against real disk: the walk itself must report the directory
    /// it could not descend into, or the protection above never engages.
    func testRecursiveScanReportsUnreadableDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MuseScanProbe-\(UUID().uuidString)")
        let open = root.appendingPathComponent("open")
        let locked = root.appendingPathComponent("locked")
        let fm = FileManager.default
        try fm.createDirectory(at: open, withIntermediateDirectories: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: open.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: locked.appendingPathComponent("b.txt"))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }

        let scan = AppState.enumerateRecursiveScan(at: root, showHidden: false)
        let names = Set(scan.nodes.map(\.url.lastPathComponent))
        XCTAssertTrue(names.contains("a.txt"))
        // The whole point: b.txt is silently absent, so the walk MUST flag its
        // directory. Without this the reconcile reads the gap as a deletion.
        XCTAssertFalse(names.contains("b.txt"))
        XCTAssertEqual(scan.unreadableDirs, [locked.standardizedFileURL.path])
    }

    func testMarkDeadChunksPastSQLiteVariableLimit() throws {
        // >999 paths in one call would blow SQLITE_MAX_VARIABLE_NUMBER if the IN
        // clause weren't chunked — the silent-no-op bug. Insert 1500 alive rows
        // and mark them all dead in a single call.
        let q = try makeQueue()
        let paths = (0..<1500).map { "/Users/me/Inspo/f\($0).jpg" }
        for p in paths { try insertAlivePath(q, p) }

        let n = PathReconciler.markDead(paths, queue: q)
        XCTAssertEqual(n, 1500)
        XCTAssertEqual(try isAlive(q, "/Users/me/Inspo/f0.jpg"), 0)
        XCTAssertEqual(try isAlive(q, "/Users/me/Inspo/f1499.jpg"), 0)
    }

    // MARK: - Existence-based whole-subtree reconcile (deep-deletion self-heal)

    func testReconcileByExistenceMarksDeepGoneFilesDead() throws {
        // The exact shape of the shipped bug: a file deep under the root whose
        // containing subfolder was deleted wholesale. A shallow (browsed-depth)
        // reconcile can never reach it; the existence pass must.
        let q = try makeQueue()
        let root = URL(fileURLWithPath: "/Users/me/Muse")
        try insertAlivePath(q, "/Users/me/Muse/Shared Collections/Articles/gone.jpg")
        try insertAlivePath(q, "/Users/me/Muse/kept.jpg")

        // On disk: only kept.jpg exists. Root is reachable (listable).
        let onDisk: Set<String> = ["/Users/me/Muse/kept.jpg"]
        let r = PathReconciler.reconcileByExistence(root: root, queue: q,
                                                    exists: { onDisk.contains($0) },
                                                    rootReachable: { _ in true })

        XCTAssertTrue(r.reachable)
        XCTAssertEqual(r.cleared, 1)
        XCTAssertEqual(try isAlive(q, "/Users/me/Muse/Shared Collections/Articles/gone.jpg"), 0)
        XCTAssertEqual(try isAlive(q, "/Users/me/Muse/kept.jpg"), 1)
    }

    func testReconcileByExistenceBailsClosedOnUnreachableRoot() throws {
        // CRITICAL data-loss guard: when the ROOT itself can't be listed (unplugged
        // external volume, un-materialized iCloud container on a cold launch, folder
        // renamed under a stale bookmark), EVERY child reports fileExists == false.
        // The pass must touch NOTHING and report not-reachable — never mass-flip the
        // whole subtree dead. (Adversarial review, post-1.3.7.)
        let q = try makeQueue()
        let root = URL(fileURLWithPath: "/Volumes/Photos")
        try insertAlivePath(q, "/Volumes/Photos/a.jpg")
        try insertAlivePath(q, "/Volumes/Photos/sub/b.jpg")

        // exists returns false for everything (disk gone), but rootReachable is false.
        let r = PathReconciler.reconcileByExistence(root: root, queue: q,
                                                    exists: { _ in false },
                                                    rootReachable: { _ in false })

        XCTAssertFalse(r.reachable)
        XCTAssertEqual(r.cleared, 0)
        XCTAssertEqual(try isAlive(q, "/Volumes/Photos/a.jpg"), 1, "must NOT mass-delete on an unreachable root")
        XCTAssertEqual(try isAlive(q, "/Volumes/Photos/sub/b.jpg"), 1)
    }

    func testReconcileByExistenceKeepsDatalessAndOutOfRoot() throws {
        // A dataless iCloud file reports fileExists == true, so `exists` returns
        // true for it — it must stay alive. And a file under a DIFFERENT root is
        // out of prefix scope and must never be touched by this root's pass.
        let q = try makeQueue()
        let root = URL(fileURLWithPath: "/Users/me/Muse")
        try insertAlivePath(q, "/Users/me/Muse/dataless.jpg")     // present (dataless)
        try insertAlivePath(q, "/Users/me/Other/x.jpg")           // different root

        let onDisk: Set<String> = ["/Users/me/Muse/dataless.jpg"]
        let r = PathReconciler.reconcileByExistence(root: root, queue: q,
                                                    exists: { onDisk.contains($0) },
                                                    rootReachable: { _ in true })

        XCTAssertTrue(r.reachable)
        XCTAssertEqual(r.cleared, 0)
        XCTAssertEqual(try isAlive(q, "/Users/me/Muse/dataless.jpg"), 1)
        XCTAssertEqual(try isAlive(q, "/Users/me/Other/x.jpg"), 1)
    }

    func testReconcileNonRecursiveIgnoresSubfolderFiles() throws {
        let q = try makeQueue()
        try insertAlivePath(q, "/Users/me/Inspo/a.jpg")
        try insertAlivePath(q, "/Users/me/Inspo/sub/deep.jpg")   // in subtree, not direct child

        // Non-recursive: subfolder file is out of scope and must stay alive even
        // though it's absent from the (shallow) present set.
        let n = PathReconciler.reconcile(
            folder: URL(fileURLWithPath: "/Users/me/Inspo"),
            recursive: false,
            present: ["/Users/me/Inspo/a.jpg"],
            queue: q)

        XCTAssertEqual(n, 0)
        XCTAssertEqual(try isAlive(q, "/Users/me/Inspo/sub/deep.jpg"), 1)
    }
}
