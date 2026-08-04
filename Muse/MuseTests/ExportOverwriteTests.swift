//
//  ExportOverwriteTests.swift
//  MuseTests
//
//  "An export can never overwrite a file the user already has — the one way
//  this feature could destroy data" is `collisionSafeURL`'s stated contract.
//  The name it returns did not exist when it looked, but the WRITE happens
//  later, and `.atomic` overwrites without complaint. These pin the write flag
//  itself, which is where the guarantee actually lives.
//

import XCTest
@testable import Muse

final class ExportOverwriteTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The behaviour the export path relies on: a write that refuses rather
    /// than replaces. Stated as a test because the two flags read as
    /// interchangeable hardening and are not.
    func testWithoutOverwritingRefusesAndLeavesTheOriginalIntact() throws {
        let f = dir.appendingPathComponent("photo.jpg")
        try Data("ORIGINAL".utf8).write(to: f)
        XCTAssertThrowsError(try Data("NEW".utf8).write(to: f, options: .withoutOverwriting))
        XCTAssertEqual(try Data(contentsOf: f), Data("ORIGINAL".utf8))
    }

    /// The flag the export sites used to carry, shown destroying the file — so
    /// the reason for the change is in the suite, not only in a comment.
    func testAtomicWouldHaveReplacedIt() throws {
        let f = dir.appendingPathComponent("photo.jpg")
        try Data("ORIGINAL".utf8).write(to: f)
        try Data("NEW".utf8).write(to: f, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: f), Data("NEW".utf8))
    }

    /// `collisionSafeURL` still does its job — the flag is the LAST line of
    /// defence, not a replacement for picking a free name.
    func testCollisionSafeURLStillAvoidsTakenNames() throws {
        try Data().write(to: dir.appendingPathComponent("photo.jpg"))
        try Data().write(to: dir.appendingPathComponent("photo-2.jpg"))
        let picked = ExportPipeline.collisionSafeURL(base: "photo", ext: "jpg", in: dir)
        XCTAssertEqual(picked.lastPathComponent, "photo-3.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: picked.path))
    }
}
