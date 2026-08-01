import XCTest
import GRDB
@testable import Muse

final class EditLutMigrationTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    func testV23CreatesEditLutsTable() throws {
        let q = try makeQueue()
        try q.read { db in XCTAssertTrue(try db.tableExists("edit_luts")) }
    }

    /// Content-addressed PK: re-importing the same `.cube` under another name
    /// dedupes rather than forking, and the first name is kept — a `lutHash`
    /// therefore resolves to byte-identical data or to nothing.
    func testContentAddressedPKConflictIsIgnored() throws {
        let q = try makeQueue()
        try q.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO edit_luts (id, name, size, data, created_at)
                VALUES ('abc123', 'First Name', 33, x'00', 0)
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO edit_luts (id, name, size, data, created_at)
                VALUES ('abc123', 'Second Name', 33, x'00', 1)
                """)
        }
        let row = try q.read { db in try EditLutRow.fetchOne(db, key: "abc123") }
        XCTAssertEqual(row?.name, "First Name")
        let count = try q.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edit_luts") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    /// LUTs are library-global like presets — no file cascade, so deleting a
    /// photo can't take a look with it.
    func testEditLutsHasNoFileForeignKey() throws {
        let q = try makeQueue()
        try q.read { db in
            let sql = try String.fetchOne(db, sql: """
                SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'edit_luts'
                """) ?? ""
            XCTAssertFalse(sql.uppercased().contains("REFERENCES"))
        }
    }

    func testMigrationIsIdempotentOnReRun() throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        XCTAssertNoThrow(try Database.makeMigrator().migrate(q))
    }
}
