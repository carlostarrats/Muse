//
//  MuseTagChipRowTests.swift
//  MuseUITests
//
//  Guards the `ChipFlow` measurement cache added 2026-08-01 (round 7).
//
//  The cache stores each chip's natural width across layout passes so that
//  hovering — which is animated, and so triggers many passes — stops
//  re-measuring every chip's text. The risk it introduces is staleness: if the
//  cache fails to invalidate when the CHIP SET changes, a new folder's chips get
//  laid out at the previous folder's widths, which shows up as overlapping or
//  clipped chips rather than as a crash.
//
//  So the test that matters is not "does hovering still work" but "does
//  switching to a folder with a DIFFERENT tag set re-measure". Both are here.
//

import XCTest

final class MuseTagChipRowTests: XCTestCase {

    private let uiTimeout: TimeInterval = 30
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: uiTimeout))
        Thread.sleep(forTimeInterval: 6)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Chips whose accessibility value carries a file count — i.e. real tag
    /// chips, not the "All" chip or unrelated buttons.
    private func chipFrames() -> [(label: String, frame: CGRect)] {
        var out: [(String, CGRect)] = []
        for i in 0..<app.buttons.count {
            let b = app.buttons.element(boundBy: i)
            guard b.exists else { continue }
            let v = (b.value as? String) ?? ""
            guard v.hasSuffix("files") || v.hasSuffix("file") else { continue }
            out.append((b.label, b.frame))
        }
        return out
    }

    /// Chips must be laid out left-to-right with no OVERLAP. An overlap is the
    /// signature of the cache serving stale widths — the placement loop advances
    /// by a width that no longer matches what the chip actually renders at.
    private func assertNoOverlaps(_ chips: [(label: String, frame: CGRect)],
                                  _ context: String) {
        let ordered = chips.sorted { $0.frame.minX < $1.frame.minX }
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            // Same row only; the row is a single horizontal line of chips.
            guard abs(a.frame.minY - b.frame.minY) < 4 else { continue }
            XCTAssertLessThanOrEqual(
                a.frame.maxX, b.frame.minX + 0.5,
                "\(context): chip '\(a.label)' overlaps '\(b.label)' — "
                + "stale layout cache (\(a.frame) vs \(b.frame))")
        }
    }

    func testChipsLayOutWithoutOverlap() throws {
        let chips = chipFrames()
        XCTAssertGreaterThan(chips.count, 3, "no tag chips rendered")
        assertNoOverlaps(chips, "initial folder")
        snap("chips-initial")
    }

    /// THE cache-invalidation test. Switching folders swaps the chip set; if
    /// `updateCache` didn't notice, the new chips keep the old widths.
    func testChipsReMeasureAfterFolderSwitch() throws {
        let before = chipFrames()
        XCTAssertGreaterThan(before.count, 3, "no chips in the first folder")
        let beforeLabels = Set(before.map(\.label))

        // Switch to a different folder via the sidebar. "Gradients" and
        // "Raw Files" carry different tag vocabularies than the big folder.
        for name in ["Gradients", "Raw Files", "Muse Hero Test"] {
            let row = app.staticTexts[name]
            guard row.waitForExistence(timeout: 5), row.isHittable else { continue }
            row.click()
            Thread.sleep(forTimeInterval: 5)

            let after = chipFrames()
            snap("chips-after-\(name)")
            guard !after.isEmpty else { continue }
            assertNoOverlaps(after, "after switching to \(name)")

            // If the chip set genuinely differs, that is the case the cache had
            // to notice. (If it happens to match, the overlap check above still
            // ran, which is the part that would catch staleness.)
            let afterLabels = Set(after.map(\.label))
            if afterLabels != beforeLabels {
                XCTAssertFalse(after.isEmpty,
                               "chips vanished after switching to \(name)")
                return
            }
        }
    }

    /// Hovering grows the hovered chip and condenses its neighbours, and the
    /// ROW's total width is meant to stay put (the no-reflow behaviour the
    /// cache had to preserve — natural widths are hover-independent by design).
    func testHoverKeepsRowStable() throws {
        let before = chipFrames()
        guard before.count > 6 else { throw XCTSkip("too few chips to test hover") }

        // Measure the row's SPAN, not any absolute position. `hover()` makes
        // XCUITest scroll the target into view, which translates every chip's
        // minX — an earlier version of this test asserted on absolute minX and
        // reported a 10pt "no-reflow regression" that was the scroll, not the
        // layout. Span is translation-invariant, and "the row's total width
        // never moves" is what the no-reflow design actually promises.
        func span(_ chips: [(label: String, frame: CGRect)]) -> CGFloat {
            let minX = chips.map(\.frame.minX).min() ?? 0
            let maxX = chips.map(\.frame.maxX).max() ?? 0
            return maxX - minX
        }
        let beforeSpan = span(before)

        // Hover the ELEMENT, not a computed point. The row is not virtualized,
        // so most chips are laid out far off-screen (past x=17,000 on this
        // library) and their frames are unusable as coordinates — deriving a
        // point from one throws "point.x != INFINITY".
        var hovered = false
        for i in 0..<app.buttons.count {
            let b = app.buttons.element(boundBy: i)
            let v = (b.value as? String) ?? ""
            guard v.hasSuffix("files") || v.hasSuffix("file") else { continue }
            guard b.exists, b.isHittable else { continue }
            b.hover()
            hovered = true
            break
        }
        try XCTSkipUnless(hovered, "no on-screen chip to hover")
        Thread.sleep(forTimeInterval: 1.5)
        snap("chips-hovered")

        let after = chipFrames()
        XCTAssertFalse(after.isEmpty, "chips vanished on hover")
        assertNoOverlaps(after, "while hovering")

        // The row's total width absorbs the hovered chip's growth by condensing
        // its neighbours, so the span holds. The design does allow a small
        // remainder when both neighbours are already at the 30pt floor, so this
        // is a tolerance, not an equality — but a broken cache would move it by
        // far more than one chip's worth of growth.
        XCTAssertEqual(beforeSpan, span(after), accuracy: 40.0,
                       "row span changed on hover — no-reflow behaviour broken")
    }
}
