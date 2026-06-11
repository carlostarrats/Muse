//
//  DeleteCoordinatorTests.swift
//  MuseTests
//
//  Burn-delete state machine: trash + remove callback + undo toast,
//  error toast on failure, re-entrancy guard while burning.
//

import XCTest
@testable import Muse

@MainActor
final class DeleteCoordinatorTests: XCTestCase {
    private func tempFile(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-delete-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data("x".utf8).write(to: url)
        return url
    }

    func testDeleteTrashesAndReportsRemoval() async throws {
        let url = try tempFile("a.png")
        let c = DeleteCoordinator()
        c.burnDuration = 0
        var removed: [URL] = []
        c.onRemove = { removed.append($0) }

        await c.deleteWithBurn(FileNode(url: url))

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(removed, [url])
        XCTAssertTrue(c.burningPaths.isEmpty)
        XCTAssertEqual(c.toast?.message, "Moved to Trash")
        XCTAssertNotNil(c.toast?.action)
    }

    func testUndoRestoresFile() async throws {
        let url = try tempFile("b.png")
        let c = DeleteCoordinator()
        c.burnDuration = 0
        var restored: [FileNode] = []
        c.onRestore = { restored.append($0) }

        await c.deleteWithBurn(FileNode(url: url))
        c.toast?.action?()   // Undo

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(restored.map(\.url), [url])
    }

    func testFailureShowsErrorToastAndReportsNothing() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-delete-tests/missing-\(UUID().uuidString).png")
        let c = DeleteCoordinator()
        c.burnDuration = 0
        var removed: [URL] = []
        c.onRemove = { removed.append($0) }

        await c.deleteWithBurn(FileNode(url: url))

        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(c.toast?.message, "Couldn't move to Trash")
        XCTAssertNil(c.toast?.action)
        XCTAssertTrue(c.burningPaths.isEmpty)
    }

    func testReentrantDeleteIgnoredWhileBurning() async throws {
        let url = try tempFile("c.png")
        let c = DeleteCoordinator()
        c.burnDuration = 0.2
        var removed: [URL] = []
        c.onRemove = { removed.append($0) }

        let first = Task { await c.deleteWithBurn(FileNode(url: url)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(c.burningPaths.contains(url.path))
        await c.deleteWithBurn(FileNode(url: url))   // guard: returns immediately
        await first.value

        XCTAssertEqual(removed, [url], "file must be trashed exactly once")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
