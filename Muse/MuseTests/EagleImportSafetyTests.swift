//
//  EagleImportSafetyTests.swift
//  MuseTests
//
//  An Eagle library is a FOLDER OF THIRD-PARTY JSON. It can be downloaded,
//  shared or synced from another machine, so every string in `metadata.json` is
//  untrusted input — and `name`/`ext` are turned into a path twice: once to
//  locate the source file inside the library, and once as the name the file is
//  copied under in the destination the user picked. A `..` in either escapes
//  both.
//

import XCTest
@testable import Muse

final class EagleImportSafetyTests: XCTestCase {
    func testTraversingNamesAreRefused() {
        for bad in ["..", ".", "../../etc/passwd", "a/b", "../secret.png",
                    "with:colon", "with\u{0}nul", ".hidden"] {
            XCTAssertNil(EagleLibrary.safeComponent(bad), "accepted \(bad)")
        }
    }

    func testOrdinaryNamesSurviveUnchanged() {
        // Rejection, not rewriting: a name that IS a component must come back
        // byte-identical, or the copy lands under a name the library never
        // asked for.
        for good in ["photo.jpg", "a b c.png", "Ünïcødé — name.tiff",
                     "no-extension", "dots.in.the.middle.raw"] {
            XCTAssertEqual(EagleLibrary.safeComponent(good), good)
        }
    }

    func testOverlongNameIsRefused() {
        XCTAssertNil(EagleLibrary.safeComponent(String(repeating: "a", count: 256)))
        XCTAssertNotNil(EagleLibrary.safeComponent(String(repeating: "a", count: 255)))
    }
}
