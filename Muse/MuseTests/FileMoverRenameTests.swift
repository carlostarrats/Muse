//
//  FileMoverRenameTests.swift
//  MuseTests
//
//  Disk-level file rename primitive (in a temp dir): renames in place, refuses a
//  collision with a different file, allows a case-only change, no-ops same name.
//

import XCTest
@testable import Muse

final class FileMoverRenameTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileMoverRenameTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeFile(_ name: String) throws -> URL {
        let u = tmp.appendingPathComponent(name)
        try Data("x".utf8).write(to: u)
        return u
    }

    func testRenamesInPlace() throws {
        let src = try makeFile("old.jpg")
        let dst = try XCTUnwrap(FileMover.rename(src, to: "new.jpg"))
        XCTAssertEqual(dst.lastPathComponent, "new.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
    }
    func testRefusesCollisionWithDifferentFile() throws {
        let src = try makeFile("a.jpg")
        _ = try makeFile("b.jpg")
        XCTAssertNil(FileMover.rename(src, to: "b.jpg"), "expected collision refusal")
        // Source is untouched on refusal.
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }
    func testAllowsCaseOnlyRename() throws {
        let src = try makeFile("Photo.jpg")
        let dst = try XCTUnwrap(FileMover.rename(src, to: "photo.jpg"))
        XCTAssertEqual(dst.lastPathComponent, "photo.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
    }
    func testSameNameIsNoopSuccess() throws {
        let src = try makeFile("same.jpg")
        let dst = try XCTUnwrap(FileMover.rename(src, to: "same.jpg"))
        XCTAssertEqual(dst.standardizedFileURL, src.standardizedFileURL)
    }
}
