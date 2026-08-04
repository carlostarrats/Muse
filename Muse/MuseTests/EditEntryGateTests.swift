//
//  EditEntryGateTests.swift
//  MuseTests
//
//  The grid's right-click ▸ Edit offers itself on exactly the files the editor
//  will actually open. That is ONE predicate with two call sites — the menu
//  item's visibility and `editModeAvailable`'s kind half — and this pins it,
//  because the failure it prevents is silent: a second copy of the image/RAW
//  list drifts, and the menu grows an item that opens a viewer with no editor
//  in it (a PSD, a video), or hides one that would have worked.
//
//  Path A is `.image` and `.raw` ONLY. `.psd` is deliberately excluded even
//  though the hero viewer displays it: what Muse can decode is its flat
//  composite, and editing that would discard the layers — Edit-a-Copy's job.
//

import XCTest
@testable import Muse

final class EditEntryGateTests: XCTestCase {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/muse-edit-gate/\(name)")
    }

    func testImagesAndRawAreEditable() {
        for name in ["a.jpg", "a.jpeg", "a.png", "a.heic", "a.tif", "a.arw", "a.cr2", "a.dng"] {
            XCTAssertTrue(HeroImageViewer.isEditableKind(url(name)),
                          "\(name) should be offered to the editor")
        }
    }

    func testPSDIsNotEditable() {
        // Displayed by the hero viewer, NOT editable — the exclusion is the
        // point, so this is its own case rather than a row in the list below.
        XCTAssertFalse(HeroImageViewer.isEditableKind(url("layers.psd")))
    }

    func testNonImageKindsAreNotEditable() {
        for name in ["clip.mp4", "clip.mov", "song.m4a", "doc.pdf", "page.svg",
                     "notes.md", "readme.txt", "sheet.csv"] {
            XCTAssertFalse(HeroImageViewer.isEditableKind(url(name)),
                           "\(name) must not offer Edit")
        }
    }

    /// The gate is extension-derived, so it answers for a path that does not
    /// exist — which is what lets the context menu build synchronously without
    /// touching the filesystem for every tile.
    func testAnswersWithoutTouchingDisk() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/photo.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertTrue(HeroImageViewer.isEditableKind(missing))
    }
}
