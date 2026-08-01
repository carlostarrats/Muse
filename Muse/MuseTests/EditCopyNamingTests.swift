import XCTest
@testable import Muse

final class EditCopyNamingTests: XCTestCase {
    func testFirstCandidateIsStemDashEdit() {
        XCTAssertEqual(EditCopyNaming.candidate(stem: "photo", ext: "jpg", existing: []),
                       "photo-Edit.jpg")
    }

    func testCollisionLadderIncrements() {
        XCTAssertEqual(EditCopyNaming.candidate(stem: "photo", ext: "jpg",
                                                existing: ["photo-Edit.jpg"]),
                       "photo-Edit-2.jpg")
        XCTAssertEqual(EditCopyNaming.candidate(stem: "photo", ext: "jpg",
                                                existing: ["photo-Edit.jpg",
                                                           "photo-Edit-2.jpg"]),
                       "photo-Edit-3.jpg")
    }

    /// macOS volumes are usually case-INSENSITIVE, so a case-sensitive match
    /// would hand back a name that then collides on disk.
    func testCollisionLadderIsCaseInsensitive() {
        XCTAssertEqual(EditCopyNaming.candidate(stem: "photo", ext: "jpg",
                                                existing: ["PHOTO-EDIT.JPG"]),
                       "photo-Edit-2.jpg")
    }

    func testUnrelatedNeighboursDoNotPushTheLadder() {
        XCTAssertEqual(EditCopyNaming.candidate(stem: "photo", ext: "jpg",
                                                existing: ["photo.jpg", "other-Edit.jpg"]),
                       "photo-Edit.jpg")
    }

    /// RAW copies render 16-bit TIFF: external editors can't write RAW back,
    /// so handing one a `.cr3` produces a file the user can open and never save.
    func testRawTargetExtensionIsTiff() {
        let raw = URL(fileURLWithPath: "/tmp/IMG_0001.CR3")
        XCTAssertEqual(EditCopyNaming.targetExtension(for: raw, isRaw: true), "tif")
    }

    func testNonRawKeepsItsContainer() {
        let png = URL(fileURLWithPath: "/tmp/shot.PNG")
        XCTAssertEqual(EditCopyNaming.targetExtension(for: png, isRaw: false), "png")
    }
}
