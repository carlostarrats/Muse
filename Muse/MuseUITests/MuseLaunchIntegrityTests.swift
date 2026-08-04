//
//  MuseLaunchIntegrityTests.swift
//  MuseUITests
//
//  What is left of `MuseSurfaceDriveTests` after 2026-08-04, and why.
//
//  That suite drove 18 surfaces — open the hero, open the editor, open every
//  modal, press Escape — and `MuseExportDriveTests` drove 7 more. Both are
//  deleted. The reasoning, so nobody rebuilds them by accident:
//
//  * **They duplicated a pass the owner already makes.** GUI verification here
//    is not automation-only; the automated run is a SECOND pass behind a human
//    one. "Does this surface open and does Escape close it" is exactly what
//    that human pass covers, faster and with better judgement.
//  * **The record is one-sided.** Across sixteen review rounds, every registry
//    entry mentioning these suites is about a defect in the SUITE: window
//    fractions that re-aimed themselves (round 9), state leaking between tests
//    and a relative drag posing as an undo (round 12), the two-instance hazard
//    (round 15), and three layers of platform disagreement (round 16b). Not one
//    entry records them catching an app regression.
//  * **They failed by accusing the app.** A fixed window fraction landing in a
//    masonry gap reported "hero viewer has no Edit toggle"; a stale window frame
//    reported "Compare is broken"; an AXDialog subrole reported "no main
//    window". Each pointed at whatever had most recently changed, which is the
//    most expensive way a test can be wrong.
//  * **They cost 45 minutes a run** and four rounds of triage.
//
//  What survives is what automation is actually better at than a person, or so
//  cheap it does not need to justify itself:
//
//  * this file — the app launches, the database opens, the migrations run and
//    the sidebar publishes real rows, in about 11 seconds;
//  * `MuseTagChipRowTests` — sub-pixel chip overlap, which an eye cannot
//    reliably catch, guarding a specific measured bug;
//  * `MuseUITestsLaunchTests` / `MuseUITests` — launch smoke.
//
//  The general rule that came out of it: **a UI test that names an element TYPE,
//  or trusts `isHittable`, is asserting about AppKit rather than about Muse.**
//  Round 9 made these tests locate the tile they click instead of computing its
//  position; the same reasoning reaches the window itself. Anything the platform
//  is free to reclassify is not a thing to assert on.
//

import XCTest

final class MuseLaunchIntegrityTests: XCTestCase {

    private let uiTimeout: TimeInterval = 30

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        // Fail here, with the reason, rather than let a second instance
        // manufacture failures that accuse the app. See SingleInstanceGuard.
        SingleInstanceGuard.assertNoOtherInstance()
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: uiTimeout),
                      "app never reached runningForeground")
        // Let the launch backfills and the first folder load settle.
        Thread.sleep(forTimeInterval: 6)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testAppLaunchesWithPopulatedSidebar() throws {
        // The sidebar's FOLDERS header is the cheapest proof the shell came up:
        // it renders only once AppState has published root nodes, which means
        // the DB opened and the migrations ran. (A bare "the window exists"
        // assertion would pass while the app did nothing.)
        //
        // The window is fetched by `awaitMainWindow` rather than `app.windows`
        // because macOS publishes it with the AXDialog subrole — see
        // MainWindowFinder.
        let window = app.awaitMainWindow(uiTimeout)
        XCTAssertTrue(window.exists, "no main window")
        XCTAssertTrue(app.staticTexts["FOLDERS"].waitForExistence(timeout: uiTimeout),
                      "sidebar did not render — DB or AppState did not publish")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "01-launch"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
