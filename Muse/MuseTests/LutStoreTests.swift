import XCTest
import GRDB
@testable import Muse

@MainActor
final class LutStoreTests: XCTestCase {

    private func makeStore() throws -> (LutStore, DatabaseQueue) {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return (LutStore(queue: q), q)
    }

    private func writeCube(title: String, size: Int = 2, value: Double = 0.5) throws -> URL {
        var lines = ["TITLE \"\(title)\"", "LUT_3D_SIZE \(size)"]
        for _ in 0..<(size * size * size) { lines.append("\(value) \(value) \(value)") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".cube")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testImportThenReloadListsTheLut() async throws {
        let (store, _) = try makeStore()
        let failures = await store.importCubes(at: [try writeCube(title: "Kodak 2383")])
        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(store.luts.contains { $0.name == "Kodak 2383" })
    }

    /// Content-addressed: identical bytes under two names is ONE row, and the
    /// first name is kept. That's what makes a `lutHash` reference a value
    /// guarantee rather than a filename.
    func testImportDedupesByHashKeepingFirstName() async throws {
        let (store, _) = try makeStore()
        _ = await store.importCubes(at: [try writeCube(title: "First")])
        _ = await store.importCubes(at: [try writeCube(title: "Second")])
        let matching = store.luts.filter { $0.name == "First" || $0.name == "Second" }
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching.first?.name, "First")
    }

    /// Rename is display-only — the id is the content hash and cannot move.
    func testRenameKeepsTheIDStable() async throws {
        let (store, _) = try makeStore()
        _ = await store.importCubes(at: [try writeCube(title: "Original")])
        let id = try XCTUnwrap(store.luts.first { $0.name == "Original" }?.id)
        await store.rename(id: id, to: "Renamed")
        XCTAssertTrue(store.luts.contains { $0.id == id && $0.name == "Renamed" })
    }

    func testDeleteRemovesFromListing() async throws {
        let (store, _) = try makeStore()
        _ = await store.importCubes(at: [try writeCube(title: "Temp")])
        let id = try XCTUnwrap(store.luts.first { $0.name == "Temp" }?.id)
        await store.delete(id: id)
        XCTAssertFalse(store.luts.contains { $0.id == id })
    }

    /// A bad file fails BY NAME and doesn't take the rest of the batch with it.
    func testImportFailureSurfacesByFilenameWithoutBlockingOthers() async throws {
        let (store, _) = try makeStore()
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bad.cube")
        try ("LUT_1D_SIZE 16\n" + String(repeating: "0.0 0.0 0.0\n", count: 16))
            .write(to: bad, atomically: true, encoding: .utf8)
        let good = try writeCube(title: "Good")
        let failures = await store.importCubes(at: [bad, good])
        XCTAssertEqual(failures.count, 1)
        XCTAssertNotNil(failures["bad.cube"])
        XCTAssertTrue(store.luts.contains { $0.name == "Good" })
    }

    /// The delete confirm's count comes from the stored stacks, so a look in
    /// use can't be removed without the user being told what it costs.
    func testReferenceCountSeesStacksAcrossAllThreeTables() async throws {
        let (store, queue) = try makeStore()
        _ = await store.importCubes(at: [try writeCube(title: "Counted")])
        let id = try XCTUnwrap(store.luts.first { $0.name == "Counted" }?.id)
        var stack = EditStack.fresh()
        stack.setLut(LutParams(lutHash: id, name: "Counted", strength: 1))
        let json = try EditStackCodec.encode(stack)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at)
                VALUES ('f1', 'h1', 'image', 0)
                """)
            try db.execute(sql: """
                INSERT INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
                VALUES ('f1', '/a', ?, 'h', 1, 0)
                """, arguments: [json])
            try db.execute(sql: """
                INSERT INTO edit_presets (id, name, stack, created_at, updated_at)
                VALUES ('p1', 'Preset', ?, 0, 0)
                """, arguments: [json])
        }
        let count = await store.referenceCount(id: id)
        XCTAssertEqual(count, 2)
    }
}
