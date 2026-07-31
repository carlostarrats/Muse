//
//  StackStoreTests.swift
//  MuseTests
//
//  create/dissolve/setPick/removeMember (auto-dissolve under two remaining);
//  claimedFileIDs includes dissolved-stack members (the auto-stacker's
//  virgin-file rule depends on it); cascade on file delete; id chunking.
//

import XCTest
import GRDB
@testable import Muse

final class StackStoreTests: XCTestCase {

    private func seeded() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at)
                VALUES ('f1','h1','image',0), ('f2','h2','image',0), ('f3','h3','image',0)
                """)
        }
        return queue
    }

    func testV17CreatesStacksTablesAndIndex() throws {
        try seeded().read { db in
            XCTAssertTrue(try db.tableExists("stacks"))
            XCTAssertTrue(try db.tableExists("stack_members"))
            XCTAssertTrue(try db.indexes(on: "stack_members")
                .contains { $0.name == "stack_members_file_idx" })
        }
    }

    func testStackMembersCascadeOnFileDelete() throws {
        let queue = try seeded()
        try queue.write { db in
            _ = try StackStore.createStack(kind: "auto", memberIDs: ["f1", "f2"], pick: nil, db: db)
            try db.execute(sql: "DELETE FROM files WHERE id = 'f1'")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stack_members") ?? -1, 1)
        }
    }

    func testCreateStackAndFetchByFileIDs() throws {
        try seeded().write { db in
            let id = try StackStore.createStack(kind: "auto", memberIDs: ["f1", "f2"],
                                                pick: "f1", db: db)
            let refs = try StackStore.stacksFor(fileIDs: ["f1", "f2", "f3"], db: db)
            XCTAssertEqual(refs["f1"]?.stackID, id)
            XCTAssertEqual(refs["f2"]?.stackID, id)
            XCTAssertNil(refs["f3"])
        }
    }

    func testDissolveTombstonesButKeepsMembers() throws {
        try seeded().write { db in
            let id = try StackStore.createStack(kind: "auto", memberIDs: ["f1", "f2"],
                                                pick: nil, db: db)
            try StackStore.dissolve(stackID: id, db: db)
            let claimed = try StackStore.claimedFileIDs(db: db)
            XCTAssertTrue(claimed.contains("f1"))
            XCTAssertTrue(claimed.contains("f2"))
            XCTAssertEqual(try StackStore.stacksFor(fileIDs: ["f1"], db: db)["f1"]?.dissolved, true)
        }
    }

    func testRemoveMemberBelowTwoAutoDissolves() throws {
        try seeded().write { db in
            let id = try StackStore.createStack(kind: "manual", memberIDs: ["f1", "f2"],
                                                pick: "f1", db: db)
            try StackStore.removeMember(stackID: id, fileID: "f2", db: db)
            XCTAssertEqual(try StackStore.stacksFor(fileIDs: ["f1"], db: db)["f1"]?.dissolved, true)
        }
    }

    func testSetPick() throws {
        try seeded().write { db in
            let id = try StackStore.createStack(kind: "manual", memberIDs: ["f1", "f2"],
                                                pick: "f1", db: db)
            try StackStore.setPick(stackID: id, fileID: "f2", db: db)
            XCTAssertEqual(try StackStore.stacksFor(fileIDs: ["f1"], db: db)["f1"]?.pickFileID, "f2")
        }
    }

    func testClaimedAndLookupChunkPastEightHundred() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        let ids = (0..<850).map { "f\($0)" }
        try queue.write { db in
            var sql = "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES "
            sql += (0..<850).map { "('f\($0)','h\($0)','image',0)" }.joined(separator: ",")
            try db.execute(sql: sql)
            _ = try StackStore.createStack(kind: "auto", memberIDs: ids, pick: nil, db: db)
        }
        try queue.read { db in
            XCTAssertEqual(try StackStore.claimedFileIDs(db: db).count, 850)
            XCTAssertEqual(try StackStore.stacksFor(fileIDs: ids, db: db).count, 850)
        }
    }
}
