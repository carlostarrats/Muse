import XCTest
import GRDB
@testable import Muse

final class LutRegistryTests: XCTestCase {

    private func makeQueueWithLut(id: String, size: Int) throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            let rgb = Data(repeating: 0, count: size * size * size * 3 * 4)
            var row = EditLutRow(id: id, name: "Test", size: size, data: rgb, created_at: 0)
            try row.insert(db)
        }
        return q
    }

    override func tearDown() {
        // The cache is process-global; a leftover entry would make the next
        // test's miss look like a hit.
        LutRegistry.invalidate("lut1")
        LutRegistry.invalidate("lut2")
        super.tearDown()
    }

    /// The stored blob is RGB (that's what the .cube declared, and what the
    /// hash covers); CIColorCube needs RGBA, so alpha is appended on read.
    func testRGBToRGBAConversionAddsAlphaChannel() throws {
        let q = try makeQueueWithLut(id: "lut1", size: 2)
        let result = LutRegistry.rgbaCube(for: "lut1", queue: q)
        XCTAssertEqual(result?.size, 2)
        XCTAssertEqual(result?.data.count, 2 * 2 * 2 * 4 * 4)
    }

    func testMissingIDReturnsNil() throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        XCTAssertNil(LutRegistry.rgbaCube(for: "nonexistent", queue: q))
    }

    /// Proves the CACHE entry cleared, not merely the row: the row is deleted
    /// after the invalidate, so a surviving cache entry would still answer.
    func testInvalidateRemovesFromCache() throws {
        let q = try makeQueueWithLut(id: "lut2", size: 2)
        XCTAssertNotNil(LutRegistry.rgbaCube(for: "lut2", queue: q))
        LutRegistry.invalidate("lut2")
        try q.write { db in try db.execute(sql: "DELETE FROM edit_luts WHERE id = 'lut2'") }
        XCTAssertNil(LutRegistry.rgbaCube(for: "lut2", queue: q))
    }

    func testCacheLimitIsEight() {
        XCTAssertEqual(LutRegistry.cacheLimit, 8)
    }
}
