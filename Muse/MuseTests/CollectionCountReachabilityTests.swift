//
//  CollectionCountReachabilityTests.swift
//  MuseTests
//
//  Lever 1 of the 2026-06-19 "shows N but opens empty" fix: the collection
//  badge count must derive from the same live, reachability-aware set the
//  opened grid can actually show — alive members UNDER an active root — so the
//  number never lies (and an out-of-root file like ~/Downloads/social.jpg, which
//  the sandbox can never display, stops inflating the count).
//

import XCTest
import GRDB
@testable import Muse

final class CollectionCountReachabilityTests: XCTestCase {

    // MARK: - Pure reachability rule

    func testIsUnderAnyRootMatchesRootItselfAndDescendants() {
        let roots = ["/Users/me/Saved Inspo", "/Users/me/Desktop/INSPO"]
        XCTAssertTrue(CollectionStore.isUnderAnyRoot("/Users/me/Saved Inspo", roots: roots))
        XCTAssertTrue(CollectionStore.isUnderAnyRoot("/Users/me/Saved Inspo/a.jpg", roots: roots))
        XCTAssertTrue(CollectionStore.isUnderAnyRoot("/Users/me/Desktop/INSPO/sub/b.jpg", roots: roots))
    }

    func testIsUnderAnyRootRejectsSiblingPrefixAndOutsiders() {
        let roots = ["/Users/me/Saved Inspo"]
        // Same string prefix but a sibling, not a child — must NOT match.
        XCTAssertFalse(CollectionStore.isUnderAnyRoot("/Users/me/Saved Inspo Extra/a.jpg", roots: roots))
        // Genuinely outside every root (the Downloads phantom).
        XCTAssertFalse(CollectionStore.isUnderAnyRoot("/Users/me/Downloads/social.jpg", roots: roots))
    }

    func testIsUnderAnyRootEmptyRootsMatchesNothing() {
        XCTAssertFalse(CollectionStore.isUnderAnyRoot("/Users/me/a.jpg", roots: []))
    }

    func testIsUnderAnyRootHandlesRealICloudRootPath() {
        // The actual reported root is a long iCloud path — it's just an ordinary
        // prefix, no special casing. (Roots always arrive standardized: no
        // trailing slash, so "$root/" composes correctly.)
        let icloud = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Archive/Saved Inspo"
        XCTAssertTrue(CollectionStore.isUnderAnyRoot(icloud + "/photo.jpg", roots: [icloud]))
        XCTAssertFalse(CollectionStore.isUnderAnyRoot("/Users/me/Downloads/social.jpg", roots: [icloud]))
    }

    // MARK: - Reachability-aware fetchAll count

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    /// file with one alive path at the given absolute path.
    private func insertFile(_ q: DatabaseQueue, id: String, at path: String) throws {
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES (?, 'image', 0)",
                           arguments: [id])
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES (?, ?, ?, 1)",
                           arguments: ["p_\(id)", id, path])
        }
    }

    func testFetchAllCountsOnlyMembersUnderAnActiveRoot() async throws {
        let q = try makeQueue()
        try insertFile(q, id: "f1", at: "/Users/me/Saved Inspo/a.jpg")
        try insertFile(q, id: "f2", at: "/Users/me/Saved Inspo/b.jpg")
        try insertFile(q, id: "f3", at: "/Users/me/Downloads/social.jpg")  // out of root
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Shopping",
                                         memberIDs: ["f1", "f2", "f3"], modelVersion: "intent-v1")

        let all = try await CollectionStore.fetchAll(queue: q, rootPaths: ["/Users/me/Saved Inspo"])
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].aliveCount, 2, "the out-of-root Downloads file must not be counted")
    }

    func testFetchAllEmptyRootsFallsBackToPureAliveCount() async throws {
        // Before AppState has pushed roots, rootPaths is empty — keep the old
        // behavior (count all alive members) rather than zeroing every count.
        let q = try makeQueue()
        try insertFile(q, id: "f1", at: "/Users/me/Saved Inspo/a.jpg")
        try insertFile(q, id: "f2", at: "/Users/me/Downloads/social.jpg")
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Shopping",
                                         memberIDs: ["f1", "f2"], modelVersion: "intent-v1")

        let all = try await CollectionStore.fetchAll(queue: q, rootPaths: [])
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].aliveCount, 2)
    }

    func testFetchAllCountsDuplicatePathsUnderRootPerPath() async throws {
        // One file_id with TWO alive paths (byte-exact duplicate in two folders,
        // both under a root) must count as 2 — the grid renders one tile PER alive
        // path. This locks the COUNT(DISTINCT file_id)→DISTINCT-path change: the
        // old count returned 1 here.
        let q = try makeQueue()
        try await q.write { db in
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('dup', 'image', 0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES (?, 'dup', ?, 1)",
                           arguments: ["p1", "/Users/me/Saved Inspo/a/x.jpg"])
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES (?, 'dup', ?, 1)",
                           arguments: ["p2", "/Users/me/Saved Inspo/b/x.jpg"])
        }
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Dups",
                                         memberIDs: ["dup"], modelVersion: "intent-v1")

        let all = try await CollectionStore.fetchAll(queue: q, rootPaths: ["/Users/me/Saved Inspo"])
        XCTAssertEqual(all[0].aliveCount, 2, "one tile per alive path, both under root")
    }

    func testFetchAllHidesAutoCollectionWithNoReachableMembers() async throws {
        // An auto collection whose only members are out-of-root has nothing the
        // grid can show — it should drop out of fetchAll just like an empty one.
        let q = try makeQueue()
        try insertFile(q, id: "f1", at: "/Users/me/Downloads/social.jpg")
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Shopping",
                                         memberIDs: ["f1"], modelVersion: "intent-v1")

        let all = try await CollectionStore.fetchAll(queue: q, rootPaths: ["/Users/me/Saved Inspo"])
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - reachableFileCount (drives the "no images → no Collections UI" gate)

    func testReachableFileCountCountsOnlyAliveUnderRoots() async throws {
        // The exact shipped shape: the only root is the empty iCloud "Muse" folder;
        // every alive file is under a DIFFERENT (removed) folder. Reachable = 0,
        // so the Collections UI must hide even though alive rows still exist.
        let q = try makeQueue()
        try insertFile(q, id: "f1", at: "/Users/me/Desktop/INSPO/a.jpg")          // removed root
        try insertFile(q, id: "f2", at: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/x.jpg")
        let muse = "/Users/me/Library/Mobile Documents/iCloud~com~tarrats~Muse/Documents"

        let count = try await CollectionStore.reachableFileCount(queue: q, rootPaths: [muse])
        XCTAssertEqual(count, 0, "nothing lives under the Muse folder → no reachable images")
    }

    func testReachableFileCountSeesFilesUnderRootAtAnyDepth() async throws {
        let q = try makeQueue()
        let muse = "/Users/me/Library/Mobile Documents/iCloud~com~tarrats~Muse/Documents"
        try insertFile(q, id: "f1", at: muse + "/photo.jpg")            // direct child
        try insertFile(q, id: "f2", at: muse + "/Trip/deep/pic.jpg")   // nested
        try insertFile(q, id: "f3", at: "/Users/me/Desktop/other.jpg") // out of root

        let count = try await CollectionStore.reachableFileCount(queue: q, rootPaths: [muse])
        XCTAssertEqual(count, 2, "both files under Muse (any depth) count; the outsider doesn't")
    }

    func testReachableFileCountEmptyRootsReturnsUnknownSentinel() async throws {
        // Before AppState pushes roots, rootPaths is empty → -1 ("unknown"), so the
        // caller keeps collections visible rather than flickering them away at launch.
        let q = try makeQueue()
        try insertFile(q, id: "f1", at: "/Users/me/Desktop/a.jpg")
        let count = try await CollectionStore.reachableFileCount(queue: q, rootPaths: [])
        XCTAssertEqual(count, -1)
    }

    func testReachableFileCountIgnoresDeadRows() async throws {
        // A ghost row (is_alive = 0) under a root must NOT count — otherwise the
        // reconcile that marks deleted files dead wouldn't let the UI hide.
        let q = try makeQueue()
        let muse = "/Users/me/Muse"
        try insertFile(q, id: "f1", at: muse + "/a.jpg")
        try await q.write { db in try db.execute(sql: "UPDATE paths SET is_alive = 0") }
        let count = try await CollectionStore.reachableFileCount(queue: q, rootPaths: [muse])
        XCTAssertEqual(count, 0)
    }
}
