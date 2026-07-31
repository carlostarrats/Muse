//
//  AutoStackerTests.swift
//  MuseTests
//
//  The virgin-file exclusion + the end-to-end write. Clustering math itself is
//  covered by BurstClustererTests.
//

import XCTest
import GRDB
@testable import Muse

final class AutoStackerTests: XCTestCase {

    /// Three identical all-zero prints one second apart: every pair clusters.
    private func seeded() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, feature_print)
                VALUES ('f1','h1','image',0,X'0000000000000000'),
                       ('f2','h2','image',0,X'0000000000000000'),
                       ('f3','h3','image',0,X'0000000000000000')
                """)
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, capture_date) VALUES ('f1',0), ('f2',2), ('f3',4)
                """)
        }
        return queue
    }

    func testVirginFilesCluster() async throws {
        let queue = try seeded()
        let created = await AutoStacker.run(fileIDs: ["f1", "f2", "f3"], dbQueue: queue)
        XCTAssertEqual(created, 1)
        try await queue.read { db in
            let refs = try StackStore.stacksFor(fileIDs: ["f1", "f2", "f3"], db: db)
            XCTAssertEqual(refs.count, 3)
            XCTAssertEqual(refs["f1"]?.stackID, refs["f3"]?.stackID)
        }
    }

    func testAlreadyClaimedFilesAreExcludedEvenWhenDissolved() async throws {
        let queue = try seeded()
        try await queue.write { db in
            // f1 is claimed by a DISSOLVED stack — permanently off-limits.
            try db.execute(sql: "INSERT INTO stacks (id, kind, dissolved, created_at) VALUES ('s0','auto',1,0)")
            try db.execute(sql: "INSERT INTO stack_members (stack_id, file_id) VALUES ('s0','f1')")
        }
        let created = await AutoStacker.run(fileIDs: ["f1", "f2", "f3"], dbQueue: queue)
        XCTAssertEqual(created, 1)
        try await queue.read { db in
            let refs = try StackStore.stacksFor(fileIDs: ["f1", "f2", "f3"], db: db)
            XCTAssertEqual(refs["f1"]?.stackID, "s0")
            XCTAssertEqual(refs["f2"]?.stackID, refs["f3"]?.stackID)
            XCTAssertNotEqual(refs["f2"]?.stackID, "s0")
        }
    }

    func testRerunIsANoOp() async throws {
        let queue = try seeded()
        _ = await AutoStacker.run(fileIDs: ["f1", "f2", "f3"], dbQueue: queue)
        let second = await AutoStacker.run(fileIDs: ["f1", "f2", "f3"], dbQueue: queue)
        XCTAssertEqual(second, 0)
    }

    func testEmptyInput() async throws {
        let queue = try seeded()
        let created = await AutoStacker.run(fileIDs: [], dbQueue: queue)
        XCTAssertEqual(created, 0)
    }
}
