import XCTest
import GRDB
@testable import Muse

final class EditRecordStoreTests: XCTestCase {
    func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1', 'h1', 'image', 0)")
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f2', 'h2', 'image', 0)")
        }
        return queue
    }

    func testWriteThenReadRoundTrips() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{}", hash: "abc", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 100, db: db)
        }
        let row = try queue.read { db in
            try EditRecordStore.read(fileID: "f1", parentDir: "/a", db: db)
        }
        XCTAssertEqual(row?.stack_hash, "abc")
        XCTAssertEqual(row?.updated_at, 100)
    }

    func testWriteUpsertsOnSameScope() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{}", hash: "abc", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 100, db: db)
            try EditRecordStore.write(stackJSON: "{}", hash: "def", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 200, db: db)
        }
        let row = try queue.read { db in
            try EditRecordStore.read(fileID: "f1", parentDir: "/a", db: db)
        }
        XCTAssertEqual(row?.stack_hash, "def")
    }

    func testDeleteRemovesRow() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{}", hash: "abc", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 100, db: db)
            try EditRecordStore.delete(fileID: "f1", parentDir: "/a", db: db)
        }
        XCTAssertNil(try queue.read { db in
            try EditRecordStore.read(fileID: "f1", parentDir: "/a", db: db)
        })
    }

    // MARK: - Hydration

    func testApplyHydratedStrictlyNewerLocalWins() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{\"local\":1}", hash: "local", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 500, db: db)
            try EditRecordStore.applyHydrated(json: "{\"incoming\":1}", incomingUpdatedAt: 100,
                                              fileID: "f1", parentDir: "/a", db: db)
        }
        let row = try queue.read { db in
            try EditRecordStore.read(fileID: "f1", parentDir: "/a", db: db)
        }
        XCTAssertEqual(row?.stack, "{\"local\":1}")
    }

    func testApplyHydratedIncomingWinsWhenNewer() throws {
        let queue = try makeQueue()
        let stack = EditStack.fresh()
        let json = try EditStackCodec.encode(stack)
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{\"local\":1}", hash: "local", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 100, db: db)
            try EditRecordStore.applyHydrated(json: json, incomingUpdatedAt: 500,
                                              fileID: "f1", parentDir: "/a", db: db)
        }
        let row = try queue.read { db in
            try EditRecordStore.read(fileID: "f1", parentDir: "/a", db: db)
        }
        XCTAssertEqual(row?.stack, json)
        // The hash is DERIVED, never trusted from the wire.
        XCTAssertEqual(row?.stack_hash, EditStackCodec.hash(stack))
    }

    func testApplyHydratedNilJSONIsASyncedReset() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{}", hash: "h", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 100, db: db)
            try EditRecordStore.applyHydrated(json: nil, incomingUpdatedAt: 500,
                                              fileID: "f1", parentDir: "/a", db: db)
        }
        XCTAssertNil(try queue.read { db in
            try EditRecordStore.read(fileID: "f1", parentDir: "/a", db: db)
        })
    }

    func testApplyHydratedUndecodableBlobStillRoundTrips() throws {
        let queue = try makeQueue()
        // A stack from a NEWER schema: must be stored byte-identical (so it
        // survives back to the device that wrote it) with a stable hash.
        let future = "{\"schemaVersion\":99,\"processVersion\":1,\"adjustments\":[],\"masks\":[]}"
        try queue.write { db in
            try EditRecordStore.applyHydrated(json: future, incomingUpdatedAt: 10,
                                              fileID: "f1", parentDir: "/a", db: db)
        }
        let row = try queue.read { db in
            try EditRecordStore.read(fileID: "f1", parentDir: "/a", db: db)
        }
        XCTAssertEqual(row?.stack, future)
        XCTAssertEqual(row?.stack_hash, EditStackCodec.hashOfRawBytes(future))
    }

    // MARK: - Carry

    func testCarryInsertOrIgnoreNeverClobbersDestination() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{\"source\":1}", hash: "s", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 100, db: db)
            try EditRecordStore.write(stackJSON: "{\"dest\":1}", hash: "d", processVersion: 1,
                                      fileID: "f2", parentDir: "/b", updatedAt: 100, db: db)
            try EditRecordStore.carry(fromFileID: "f1", fromDir: "/a", toFileID: "f2",
                                      toDir: "/b", deleteOriginal: false, db: db)
        }
        let row = try queue.read { db in
            try EditRecordStore.read(fileID: "f2", parentDir: "/b", db: db)
        }
        XCTAssertEqual(row?.stack, "{\"dest\":1}")
    }

    func testCarryCopyKeepsSource() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{\"source\":1}", hash: "s", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 100, db: db)
            try EditRecordStore.carry(fromFileID: "f1", fromDir: "/a", toFileID: "f2",
                                      toDir: "/b", deleteOriginal: false, db: db)
        }
        try queue.read { db in
            XCTAssertNotNil(try EditRecordStore.read(fileID: "f1", parentDir: "/a", db: db))
            XCTAssertEqual(try EditRecordStore.read(fileID: "f2", parentDir: "/b", db: db)?.stack,
                           "{\"source\":1}")
        }
    }

    func testCarryWithDeleteOriginalRemovesSource() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{\"source\":1}", hash: "s", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 100, db: db)
            try EditRecordStore.carry(fromFileID: "f1", fromDir: "/a", toFileID: "f2",
                                      toDir: "/b", deleteOriginal: true, db: db)
        }
        try queue.read { db in
            XCTAssertNil(try EditRecordStore.read(fileID: "f1", parentDir: "/a", db: db))
            XCTAssertNotNil(try EditRecordStore.read(fileID: "f2", parentDir: "/b", db: db))
        }
    }

    /// Carried versions get FRESH ids — reusing the PK would silently drop
    /// every version but the first when two scopes merge.
    func testCarryGivesVersionsFreshIDs() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.addVersion(
                EditVersionRow(id: "v1", file_id: "f1", parent_dir: "/a", kind: "version",
                               name: "One", stack: "{}", created_at: 1), db: db)
            try EditRecordStore.addVersion(
                EditVersionRow(id: "v2", file_id: "f1", parent_dir: "/a", kind: "snapshot",
                               name: "Two", stack: "{}", created_at: 2), db: db)
            try EditRecordStore.carry(fromFileID: "f1", fromDir: "/a", toFileID: "f2",
                                      toDir: "/b", deleteOriginal: false, db: db)
        }
        let carried = try queue.read { db in
            try EditRecordStore.versions(fileID: "f2", parentDir: "/b", db: db)
        }
        XCTAssertEqual(carried.count, 2)
        XCTAssertEqual(Set(carried.map(\.name)), ["One", "Two"])
        XCTAssertFalse(carried.contains { $0.id == "v1" || $0.id == "v2" })
    }

    func testCarryAllMovesEveryScope() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{\"a\":1}", hash: "a", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 1, db: db)
            try EditRecordStore.write(stackJSON: "{\"b\":1}", hash: "b", processVersion: 1,
                                      fileID: "f1", parentDir: "/b", updatedAt: 1, db: db)
            try EditRecordStore.carryAll(fromFileID: "f1", toFileID: "f2", db: db)
        }
        try queue.read { db in
            XCTAssertEqual(try EditRecordStore.read(fileID: "f2", parentDir: "/a", db: db)?.stack,
                           "{\"a\":1}")
            XCTAssertEqual(try EditRecordStore.read(fileID: "f2", parentDir: "/b", db: db)?.stack,
                           "{\"b\":1}")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edits WHERE file_id = 'f1'"), 0)
        }
    }

    /// A reset clears the stack but keeps its versions, so `carryAll` has to
    /// sweep version rows in scopes the `edits` table no longer mentions.
    func testCarryAllMovesVersionsWithNoCurrentStack() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.addVersion(
                EditVersionRow(id: "v1", file_id: "f1", parent_dir: "/orphan", kind: "version",
                               name: "Kept", stack: "{}", created_at: 1), db: db)
            try EditRecordStore.carryAll(fromFileID: "f1", toFileID: "f2", db: db)
        }
        let carried = try queue.read { db in
            try EditRecordStore.versions(fileID: "f2", parentDir: "/orphan", db: db)
        }
        XCTAssertEqual(carried.map(\.name), ["Kept"])
    }

    // MARK: - Folder rename

    func testRewriteParentDirPrefixMovesExactAndChildScopes() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{\"x\":1}", hash: "x", processVersion: 1,
                                      fileID: "f1", parentDir: "/root/Old", updatedAt: 1, db: db)
            try EditRecordStore.write(stackJSON: "{\"y\":1}", hash: "y", processVersion: 1,
                                      fileID: "f2", parentDir: "/root/Old/Sub", updatedAt: 1, db: db)
            try EditRecordStore.rewriteParentDirPrefix(oldPrefix: "/root/Old",
                                                       newPrefix: "/root/New", db: db)
        }
        try queue.read { db in
            XCTAssertNotNil(try EditRecordStore.read(fileID: "f1", parentDir: "/root/New", db: db))
            XCTAssertNotNil(try EditRecordStore.read(fileID: "f2", parentDir: "/root/New/Sub", db: db))
        }
    }

    /// A sibling folder must NOT be caught by a bare prefix match — the whole
    /// reason the SQL uses `SUBSTR(…) = :old || '/'` rather than `LIKE`.
    func testRewriteParentDirPrefixLeavesSiblingsAlone() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{\"s\":1}", hash: "s", processVersion: 1,
                                      fileID: "f1", parentDir: "/root/OldStuff", updatedAt: 1, db: db)
            try EditRecordStore.rewriteParentDirPrefix(oldPrefix: "/root/Old",
                                                       newPrefix: "/root/New", db: db)
        }
        XCTAssertNotNil(try queue.read { db in
            try EditRecordStore.read(fileID: "f1", parentDir: "/root/OldStuff", db: db)
        })
    }

    /// A stale row already sitting at the new prefix would otherwise collide
    /// with the composite PK and roll back the whole rename transaction.
    func testRewriteParentDirPrefixPreClearsStaleTarget() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{\"stale\":1}", hash: "stale", processVersion: 1,
                                      fileID: "f1", parentDir: "/root/New", updatedAt: 1, db: db)
            try EditRecordStore.write(stackJSON: "{\"live\":1}", hash: "live", processVersion: 1,
                                      fileID: "f1", parentDir: "/root/Old", updatedAt: 2, db: db)
            try EditRecordStore.rewriteParentDirPrefix(oldPrefix: "/root/Old",
                                                       newPrefix: "/root/New", db: db)
        }
        XCTAssertEqual(try queue.read { db in
            try EditRecordStore.read(fileID: "f1", parentDir: "/root/New", db: db)?.stack
        }, "{\"live\":1}")
    }

    // MARK: - Versions CRUD

    func testVersionsCRUD() throws {
        let queue = try makeQueue()
        let versionRow = EditVersionRow(id: "v1", file_id: "f1", parent_dir: "/a",
                                        kind: "snapshot", name: "Snap 1", stack: "{}",
                                        created_at: 100)
        try queue.write { db in try EditRecordStore.addVersion(versionRow, db: db) }
        var versions = try queue.read { db in
            try EditRecordStore.versions(fileID: "f1", parentDir: "/a", db: db)
        }
        XCTAssertEqual(versions.count, 1)
        try queue.write { db in try EditRecordStore.deleteVersion(id: "v1", db: db) }
        versions = try queue.read { db in
            try EditRecordStore.versions(fileID: "f1", parentDir: "/a", db: db)
        }
        XCTAssertEqual(versions.count, 0)
    }

    // MARK: - Index bulk load

    func testAllWithAlivePathsOnlyMatchesTheEditsOwnFolder() throws {
        let queue = try makeQueue()
        try queue.write { db in
            // One identity alive at two paths; the edit belongs to /a only.
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1', 'f1', '/a/x.jpg', 1)
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p2', 'f1', '/b/x.jpg', 1)
                """)
            try EditRecordStore.write(stackJSON: "{\"e\":1}", hash: "e", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 1, db: db)
        }
        let entries = try queue.read { db in try EditRecordStore.allWithAlivePaths(db: db) }
        XCTAssertEqual(entries.map(\.path), ["/a/x.jpg"])
    }

    // MARK: - Scoped variants (the per-save path)

    /// `withAlivePaths` must agree with the bulk load on the rows it covers —
    /// including the per-folder filter, which is the whole reason a copy in
    /// another folder doesn't inherit the edit.
    func testWithAlivePathsMatchesTheBulkLoadForItsScope() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1', 'f1', '/a/x.jpg', 1)
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p2', 'f1', '/b/x.jpg', 1)
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p3', 'f2', '/a/y.jpg', 1)
                """)
            try EditRecordStore.write(stackJSON: "{\"e\":1}", hash: "e", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 1, db: db)
            try EditRecordStore.write(stackJSON: "{\"e\":2}", hash: "e2", processVersion: 1,
                                      fileID: "f2", parentDir: "/a", updatedAt: 1, db: db)
        }
        let scoped = try queue.read { db in
            try EditRecordStore.withAlivePaths(["/a/x.jpg", "/b/x.jpg"], db: db)
        }
        XCTAssertEqual(scoped.map(\.path), ["/a/x.jpg"])
        XCTAssertEqual(scoped.first?.hash, "e")

        let all = try queue.read { db in try EditRecordStore.allWithAlivePaths(db: db) }
        XCTAssertEqual(Set(all.map(\.path)), ["/a/x.jpg", "/a/y.jpg"])
    }

    func testWithAlivePathsIsEmptyForNoPaths() throws {
        let queue = try makeQueue()
        let scoped = try queue.read { db in try EditRecordStore.withAlivePaths([], db: db) }
        XCTAssertTrue(scoped.isEmpty)
    }

    func testScopedVersionCountsMatchTheFullMap() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1', 'f1', '/a/x.jpg', 1)
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p3', 'f2', '/a/y.jpg', 1)
                """)
            for i in 0..<3 {
                try EditRecordStore.addVersion(
                    EditVersionRow(id: "v\(i)", file_id: "f1", parent_dir: "/a",
                                   kind: "version", name: "n\(i)", stack: "{}",
                                   created_at: Int64(i)), db: db)
            }
            try EditRecordStore.addVersion(
                EditVersionRow(id: "v9", file_id: "f2", parent_dir: "/a",
                               kind: "version", name: "n", stack: "{}", created_at: 0), db: db)
        }
        let full = try queue.read { db in try EditRecordStore.versionCounts(db: db) }
        let scoped = try queue.read { db in
            try EditRecordStore.versionCounts(forPaths: ["/a/x.jpg"], db: db)
        }
        XCTAssertEqual(full["/a/x.jpg"], 3)
        XCTAssertEqual(scoped, ["/a/x.jpg": 3])
        XCTAssertNil(scoped["/a/y.jpg"], "the scoped query must not leak other paths")
    }

    /// A path with no versions yields no entry — that absence is what removes
    /// the grid badge when the last version is deleted.
    func testScopedVersionCountsOmitsPathsWithNoVersions() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1', 'f1', '/a/x.jpg', 1)
                """)
        }
        let scoped = try queue.read { db in
            try EditRecordStore.versionCounts(forPaths: ["/a/x.jpg"], db: db)
        }
        XCTAssertTrue(scoped.isEmpty)
    }
}
