//
//  FolderOpsTests.swift
//  MuseTests
//
//  Folder create/rename validation + disk operations (in a temp dir).
//

import XCTest
@testable import Muse

final class FolderOpsTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FolderOpsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testSanitizeRejectsEmpty() {
        XCTAssertEqual(FolderOps.sanitize("   "), .failure(.emptyName))
    }
    func testSanitizeRejectsSlashAndColon() {
        XCTAssertEqual(FolderOps.sanitize("a/b"), .failure(.invalidName))
        XCTAssertEqual(FolderOps.sanitize("a:b"), .failure(.invalidName))
        XCTAssertEqual(FolderOps.sanitize(".."), .failure(.invalidName))
    }
    func testSanitizeTrimsWhitespace() {
        XCTAssertEqual(FolderOps.sanitize("  Photos  "), .success("Photos"))
    }
    func testCreateSubfolderMakesDirectory() throws {
        let result = FolderOps.createSubfolder(named: "New", in: tmp)
        let url = try XCTUnwrap(try? result.get())
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(url.lastPathComponent, "New")
    }
    func testCreateSubfolderCollision() throws {
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("Dup"), withIntermediateDirectories: false)
        XCTAssertEqual(FolderOps.createSubfolder(named: "Dup", in: tmp), .failure(.collision))
    }
    func testRenameMovesFolder() throws {
        let src = tmp.appendingPathComponent("Before")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: false)
        let result = FolderOps.rename(src, to: "After")
        let dst = try XCTUnwrap(try? result.get())
        XCTAssertEqual(dst.lastPathComponent, "After")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
    }
    func testRenameCollision() throws {
        let src = tmp.appendingPathComponent("A")
        let other = tmp.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        XCTAssertEqual(FolderOps.rename(src, to: "B"), .failure(.collision))
    }
    func testRenameToSameNameSucceedsNoop() throws {
        let src = tmp.appendingPathComponent("Same")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: false)
        let dst = try XCTUnwrap(try? FolderOps.rename(src, to: "Same").get())
        XCTAssertEqual(dst.standardizedFileURL, src.standardizedFileURL)
    }
}
