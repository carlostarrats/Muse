import XCTest
import GRDB
@testable import Muse

final class EditMigrationTests: XCTestCase {
    func makeMigratedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        return queue
    }

    func testV20CreatesEditsAndEditVersionsTables() throws {
        let queue = try makeMigratedQueue()
        try queue.read { db in
            XCTAssertTrue(try db.tableExists("edits"))
            XCTAssertTrue(try db.tableExists("edit_versions"))
        }
    }

    func testEditsTableHasCompositePrimaryKeyOnFileIdParentDir() throws {
        let queue = try makeMigratedQueue()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1', 'h1', 'image', 0)")
            try db.execute(sql: """
                INSERT INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
                VALUES ('f1', '/a', '{}', 'h', 1, 0)
                """)
            // Same file in a DIFFERENT folder is a different edit — this is the
            // whole reason the stack isn't a column on `files`.
            try db.execute(sql: """
                INSERT INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
                VALUES ('f1', '/b', '{}', 'h2', 1, 0)
                """)
        }
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edits"), 2)
        }
    }

    func testEditsRejectsDuplicateScope() throws {
        let queue = try makeMigratedQueue()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1', 'h1', 'image', 0)")
            try db.execute(sql: """
                INSERT INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
                VALUES ('f1', '/a', '{}', 'h', 1, 0)
                """)
        }
        XCTAssertThrowsError(try queue.write { db in
            try db.execute(sql: """
                INSERT INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
                VALUES ('f1', '/a', '{}', 'h', 1, 0)
                """)
        })
    }

    func testEditsCascadeDeleteOnFileDelete() throws {
        let queue = try makeMigratedQueue()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f2', 'h2', 'image', 0)")
            try db.execute(sql: """
                INSERT INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
                VALUES ('f2', '/a', '{}', 'h', 1, 0)
                """)
            try db.execute(sql: """
                INSERT INTO edit_versions (id, file_id, parent_dir, kind, name, stack, created_at)
                VALUES ('v1', 'f2', '/a', 'version', 'v', '{}', 0)
                """)
            try db.execute(sql: "DELETE FROM files WHERE id = 'f2'")
        }
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edits"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edit_versions"), 0)
        }
    }

    func testV21CreatesEditPresetsTable() throws {
        let queue = try makeMigratedQueue()
        try queue.read { db in XCTAssertTrue(try db.tableExists("edit_presets")) }
    }

    func testEditPresetsAllowsDuplicateNames() throws {
        let queue = try makeMigratedQueue()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO edit_presets (id, name, stack, created_at, updated_at) VALUES ('p1', 'Warm', '{}', 0, 0)")
            try db.execute(sql: "INSERT INTO edit_presets (id, name, stack, created_at, updated_at) VALUES ('p2', 'Warm', '{}', 0, 0)")
        }
        try queue.read { db in
            // No UNIQUE on name — two looks called "Warm" is the user's business.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edit_presets"), 2)
        }
    }

    func testMigrationIsIdempotentOnReRun() throws {
        let queue = try makeMigratedQueue()
        XCTAssertNoThrow(try Database.makeMigrator().migrate(queue))
    }

    /// Existing rows survive the new migrations — the "runs clean on the prior
    /// version's library" half of the house migration-test convention.
    func testPriorTablesUntouchedByV20V21() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f9', 'h9', 'image', 0)")
            try db.execute(sql: """
                INSERT INTO notes (file_id, parent_dir, body, updated_at)
                VALUES ('f9', '/a', 'kept', 1)
                """)
        }
        try Database.makeMigrator().migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT body FROM notes WHERE file_id = 'f9'"),
                           "kept")
        }
    }
}
