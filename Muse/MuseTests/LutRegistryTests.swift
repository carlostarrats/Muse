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

    // MARK: - Stored (size, blob) pairs that don't describe a cube
    //
    // `CIColorCubeWithColorSpace` reads size³ × 4 floats out of `inputCubeData`
    // and takes `inputCubeDimension` on trust. `CubeLUTParser` guarantees the
    // pair matches for anything IMPORTED, but a restored `.muselibrary` writes
    // `edit_luts` rows with a plain INSERT — so the archive is where a
    // mismatched pair enters. Refusing here makes the referencing stack
    // unrenderable, which means the ORIGINAL renders.

    /// A row whose declared size outruns its blob: the exact shape that would
    /// have Core Image read past the end of the buffer.
    func testDeclaredSizeLargerThanBlobIsRefused() throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            // Blob sized for a 2³ cube, row claiming 16³.
            let rgb = Data(repeating: 0, count: 2 * 2 * 2 * 3 * 4)
            var row = EditLutRow(id: "bad", name: "Bad", size: 16, data: rgb, created_at: 0)
            try row.insert(db)
        }
        XCTAssertNil(LutRegistry.rgbaCube(for: "bad", queue: q))
        LutRegistry.invalidate("bad")
    }

    func testDeclaredSizeSmallerThanBlobIsRefused() throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            let rgb = Data(repeating: 0, count: 8 * 8 * 8 * 3 * 4)
            var row = EditLutRow(id: "bad2", name: "Bad", size: 2, data: rgb, created_at: 0)
            try row.insert(db)
        }
        XCTAssertNil(LutRegistry.rgbaCube(for: "bad2", queue: q))
        LutRegistry.invalidate("bad2")
    }

    /// The predicate itself, over the boundaries the parser enforces on import.
    func testIsRenderableStoredCubeBoundaries() {
        let floats = MemoryLayout<Float>.size
        XCTAssertTrue(CubeLUT.isRenderableStoredCube(size: 2, byteCount: 2 * 2 * 2 * 3 * floats))
        XCTAssertTrue(CubeLUT.isRenderableStoredCube(
            size: CubeLUTParser.maxSize,
            byteCount: CubeLUTParser.maxSize * CubeLUTParser.maxSize
                * CubeLUTParser.maxSize * 3 * floats))
        // Past CIColorCube's documented ceiling — and the cube of a large size
        // is where an unchecked value would also overflow the byte arithmetic.
        XCTAssertFalse(CubeLUT.isRenderableStoredCube(size: CubeLUTParser.maxSize + 1,
                                                      byteCount: 1))
        XCTAssertFalse(CubeLUT.isRenderableStoredCube(size: 1, byteCount: 3 * floats))
        XCTAssertFalse(CubeLUT.isRenderableStoredCube(size: 0, byteCount: 0))
        XCTAssertFalse(CubeLUT.isRenderableStoredCube(size: -2, byteCount: 0))
        XCTAssertFalse(CubeLUT.isRenderableStoredCube(size: 2, byteCount: 0))
    }

    /// Every cube the PARSER produces must satisfy the predicate — otherwise the
    /// guard would reject the app's own imports, which is the failure mode a
    /// too-strict check has.
    func testParsedCubeSatisfiesTheStoredPredicate() throws {
        var text = "LUT_3D_SIZE 2\n"
        for i in 0..<8 { text += "\(Float(i) / 8) 0.5 0.25\n" }
        let parsed = try CubeLUTParser.parse(text)
        XCTAssertTrue(CubeLUT.isRenderableStoredCube(
            size: parsed.lut.size,
            byteCount: parsed.lut.canonicalData.count))
    }
}
