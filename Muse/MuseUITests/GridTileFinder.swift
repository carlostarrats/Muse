//
//  GridTileFinder.swift
//  MuseUITests
//
//  Find a photo tile in the grid, for the tests that need to open one.
//
//  This replaces a magic window fraction — `(0.55, 0.5)` — that every
//  photo-opening test in both drive suites used. Two things are wrong with a
//  fraction, and the second one bit on 2026-08-02:
//
//    1. It is aimed by the WINDOW's size, and macOS restores the window frame
//       between runs. A developer resizing the window by hand (or a change to
//       the window's minimum size) silently re-aims every test.
//    2. The grid is ragged masonry, so a fraction that used to land on a tile
//       can land in the GAP between two — which clears the selection instead of
//       opening anything. Six tests failed that way with the app working
//       perfectly, and the failure message ("hero viewer has no Edit toggle")
//       pointed at the editor rather than at the click.
//
//  Tiles are buttons labelled with their filename, so they can simply be found.
//

import XCTest

extension XCUIApplication {
    /// The first photo tile in the grid, or nil if the grid has none.
    ///
    /// Matched on a file extension rather than a hardcoded filename: these
    /// suites run against the developer's real library, and naming a photo
    /// would tie them to one machine's contents.
    func firstPhotoTile() -> XCUIElement? {
        let extensions = [".jpg", ".jpeg", ".png", ".heic", ".heif",
                          ".arw", ".cr2", ".nef", ".dng", ".tif", ".tiff", ".webp"]
        for i in 0..<buttons.count {
            let button = buttons.element(boundBy: i)
            let label = button.label.lowercased()
            guard extensions.contains(where: { label.hasSuffix($0) }) else { continue }
            guard button.exists, button.isHittable else { continue }
            return button
        }
        return nil
    }
}

extension XCTestCase {
    /// Click a tile's OWN centre.
    ///
    /// Via an explicit coordinate rather than `element.click()`: XCUITest's
    /// hit-point resolution fails inside the grid's transparent ScrollView,
    /// which is why the suite has a `hit()` helper at all.
    ///
    /// Returns false (having failed the test) when the grid has no photos, so
    /// callers can `guard` and stop rather than going on to assert against a
    /// surface that was never opened.
    @discardableResult
    func openPhoto(in app: XCUIApplication, doubleClick: Bool = true,
                   settle: TimeInterval = 4,
                   file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard let tile = app.firstPhotoTile() else {
            XCTFail("no photo tile found in the grid", file: file, line: line)
            return false
        }
        let centre = tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Double-click OPENS (GridView.handleTileTap does its own detection);
        // single-click only selects. Return does not open either — an early
        // version of these tests pressed it and passed while doing nothing.
        if doubleClick { centre.doubleClick() } else { centre.click() }
        Thread.sleep(forTimeInterval: settle)
        return true
    }
}
