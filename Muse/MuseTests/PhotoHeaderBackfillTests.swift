//
//  PhotoHeaderBackfillTests.swift
//  MuseTests
//
//  The pure candidate filter — the selection rule that decides whether the
//  pass terminates. A kind PhotoHeaderReader can't handle would never get a
//  scanned hash, so admitting it means re-selecting it on every launch forever.
//

import XCTest
@testable import Muse

final class PhotoHeaderBackfillTests: XCTestCase {

    func testAdmitsReadableKinds() {
        XCTAssertNotNil(PhotoHeaderBackfill.candidate(id: "a", path: "/tmp/a.jpg"))
        XCTAssertNotNil(PhotoHeaderBackfill.candidate(id: "b", path: "/tmp/b.dng"))
        XCTAssertNotNil(PhotoHeaderBackfill.candidate(id: "c", path: "/tmp/c.mov"))
    }

    func testRejectsKindsTheReaderCannotHandle() {
        XCTAssertNil(PhotoHeaderBackfill.candidate(id: "d", path: "/tmp/d.txt"))
        XCTAssertNil(PhotoHeaderBackfill.candidate(id: "e", path: "/tmp/e.pdf"))
        XCTAssertNil(PhotoHeaderBackfill.candidate(id: "f", path: "/tmp/f.ttf"))
    }

    func testCarriesDetectedKind() {
        XCTAssertEqual(PhotoHeaderBackfill.candidate(id: "a", path: "/tmp/a.jpg")?.kind, .image)
        XCTAssertEqual(PhotoHeaderBackfill.candidate(id: "c", path: "/tmp/c.mov")?.kind, .video)
    }
}
