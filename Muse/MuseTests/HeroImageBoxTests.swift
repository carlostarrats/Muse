import XCTest
@testable import Muse

/// The hero stage's latest decode, held for the editor to open on.
///
/// The guard under test is a file-identity one: an arrow-key flip moves the
/// viewer's current URL the instant the key is pressed, while the new file's
/// decode is still in flight — so the box is holding the PREVIOUS photo's
/// pixels at that moment. Handing those to a new `EditSession` would open the
/// editor on the wrong picture.
final class HeroImageBoxTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/tmp/a.jpg")
    private let b = URL(fileURLWithPath: "/tmp/b.jpg")

    private func swatch() -> NSImage {
        let img = NSImage(size: NSSize(width: 4, height: 4))
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        img.unlockFocus()
        return img
    }

    func testEmptyBoxYieldsNothing() {
        XCTAssertNil(HeroImageBox().image(for: a))
    }

    func testStoredImageComesBackForItsOwnFile() {
        let box = HeroImageBox()
        let image = swatch()
        box.store(image, for: a)
        XCTAssertIdentical(box.image(for: a), image)
    }

    /// The flip race: current URL is already B, the box still holds A.
    func testStoredImageIsWithheldFromAnotherFile() {
        let box = HeroImageBox()
        box.store(swatch(), for: a)
        XCTAssertNil(box.image(for: b))
    }

    /// The stage lands three decode rungs per file; the last one wins.
    func testLaterDecodeReplacesTheEarlierOne() {
        let box = HeroImageBox()
        box.store(swatch(), for: a)
        let sharp = swatch()
        box.store(sharp, for: a)
        XCTAssertIdentical(box.image(for: a), sharp)
    }

    /// Storing B must not leave A readable — otherwise flipping back would
    /// serve a stale image the stage has since replaced.
    func testStoringANewFileDropsThePreviousOne() {
        let box = HeroImageBox()
        box.store(swatch(), for: a)
        box.store(swatch(), for: b)
        XCTAssertNil(box.image(for: a))
    }
}
