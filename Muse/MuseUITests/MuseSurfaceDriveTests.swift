//
//  MuseSurfaceDriveTests.swift
//  MuseUITests
//
//  Ledger gap G1: "almost nothing on this branch has been driven in the running
//  GUI." This is the automated half of closing it — one test per surface the
//  ledger lists as never driven, each one opening the surface for real and
//  asserting something only a working surface can satisfy.
//
//  Scope and deliberate omissions:
//
//  * NON-DESTRUCTIVE ONLY. These run against the developer's real library.
//    Restore-from-backup, delete, and Drive publish are excluded — the first two
//    mutate user data and the third needs network plus an OAuth session.
//  * Each modal is also closed with ESCAPE, which makes these a standing
//    regression test for review round 1's F16 (five new modals gated the grid's
//    key catcher with no Escape branch, breaking grid keyboard nav).
//  * `continueAfterFailure = true` throughout: a surface that fails to open
//    should not hide the state of the surfaces after it.
//
//  These assert that a surface OPENS and RESPONDS. They do not assert that its
//  feature is correct — that still needs a human, and the ledger's Runtime
//  column stays the record of what a person actually saw.
//

import XCTest

final class MuseSurfaceDriveTests: XCTestCase {

    /// Long, because the first folder load on a ~1,900-file library has to get
    /// through indexing and thumbnail prewarm before the grid publishes.
    private let uiTimeout: TimeInterval = 30

    private var app: XCUIApplication!

    override func setUpWithError() throws {
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

    // MARK: - Helpers

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Dump the element tree for a surface, so assertions can be written
    /// against what the surface ACTUALLY publishes rather than what it is
    /// assumed to. Written to a shared directory since the runner is sandboxed.
    private func dumpTree(_ name: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let out = dir.appendingPathComponent("muse-tree-\(name).txt")
        try? app.debugDescription.write(to: out, atomically: true, encoding: .utf8)
        print("TREE \(name): \(out.path)")
    }

    /// Labels of every hittable button, the practical vocabulary for assertions.
    private func buttonLabels() -> Set<String> {
        var out: Set<String> = []
        for i in 0..<app.buttons.count {
            let b = app.buttons.element(boundBy: i)
            let l = b.label
            if !l.isEmpty { out.insert(l) }
        }
        return out
    }

    /// Click a menu bar item's child by title. Menus are the most reliable
    /// handle on this app: the toolbar is glass capsules whose buttons carry
    /// symbol identifiers, but every feature entry point also has a menu item.
    @discardableResult
    private func menu(_ bar: String, _ item: String,
                      submenu: String? = nil,
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let barItem = app.menuBars.menuBarItems[bar]
        guard barItem.waitForExistence(timeout: uiTimeout) else {
            XCTFail("menu bar item '\(bar)' not found", file: file, line: line)
            return false
        }
        barItem.click()
        if let submenu {
            let parent = app.menuBars.menuItems[submenu]
            guard parent.waitForExistence(timeout: 5) else {
                XCTFail("submenu '\(submenu)' not found", file: file, line: line)
                return false
            }
            parent.hover()
        }
        let target = app.menuBars.menuItems[item]
        guard target.waitForExistence(timeout: 5) else {
            XCTFail("menu item '\(item)' not found under '\(bar)'", file: file, line: line)
            return false
        }
        guard target.isEnabled else {
            // Not a failure by itself — several items are contextual. The caller
            // decides whether disabled is the expected state.
            app.typeKey(.escape, modifierFlags: [])
            return false
        }
        target.click()
        return true
    }

    /// Select the first grid tile. The grid publishes tiles as images inside the
    /// content group; clicking the group's centre is what a user does.
    private func selectFirstTile() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: uiTimeout), "no main window")
        // Click into the grid area — right of the sidebar, below the chip row.
        let grid = window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        grid.click()
        Thread.sleep(forTimeInterval: 1.5)
    }

    // MARK: - The library shell

    func testAppLaunchesWithPopulatedSidebar() throws {
        // The sidebar's library rows are the cheapest proof the DB opened, the
        // migrations ran, and AppState published: they are rendered from real
        // rows, not placeholders.
        for label in ["Places", "On This Day", "Rarely Seen", "Shuffle"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: uiTimeout),
                          "sidebar row '\(label)' missing — DB or AppState did not publish")
        }
        snap("01-launch")
    }

    func testRediscoverySurfacesOpen() throws {
        // Spec 02's rediscovery surfaces. Each replaces the grid content, so the
        // proof is that the app survives the switch and the row stays hittable.
        for label in ["Places", "On This Day", "Rarely Seen", "Shuffle"] {
            let row = app.buttons[label]
            guard row.waitForExistence(timeout: uiTimeout) else {
                XCTFail("row '\(label)' missing"); continue
            }
            row.click()
            Thread.sleep(forTimeInterval: 3)
            // A LIVENESS check, labelled honestly: it proves the switch didn't
            // crash or wedge the UI behind a modal, not that the surface shows
            // the right content. The screenshot is the record of the latter.
            XCTAssertTrue(app.windows.firstMatch.exists,
                          "window gone after opening '\(label)'")
            XCTAssertTrue(app.buttons["Shuffle"].isHittable,
                          "UI unresponsive after opening '\(label)'")
            snap("02-rediscovery-\(label)")
        }
    }

    // MARK: - Hero viewer + editor (Spec 04)

    /// A DOUBLE-CLICK opens the viewer, not Return — `GridView.handleTileTap`
    /// does its own double-click detection so single-click selection stays
    /// instant. The first version of this test pressed Return, which only
    /// selects, and still PASSED because it asserted nothing but "the window
    /// exists". That is the exact "compiles, passes, does nothing" failure this
    /// suite is meant to catch, so the assertion is now a hero-ONLY control.
    func testHeroViewerOpensAndEscapeCloses() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: uiTimeout), "no main window")
        let tile = window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        tile.doubleClick()
        Thread.sleep(forTimeInterval: 4)
        snap("03-hero-open")
        dumpTree("hero")

        // "Zoom out" and "Share" are hero-chrome controls with no counterpart
        // in the grid, so their presence is real proof the viewer opened.
        let labels = buttonLabels()
        let heroOpen = labels.contains("Zoom out") || labels.contains("Share")
        XCTAssertTrue(heroOpen,
                      "hero viewer did not open on double-click; buttons were: "
                      + labels.sorted().prefix(25).joined(separator: ", "))

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 3)
        snap("03-hero-closed")
        let after = buttonLabels()
        XCTAssertFalse(after.contains("Zoom out"),
                       "Escape did not close the hero viewer — 'Zoom out' still present")
    }

    /// Spec 04's editor is the largest thing on this branch and the least
    /// exercised. The hero viewer carries a (Preview | Edit) pair; switching to
    /// Edit must bring up adjustment controls, not just re-label the toggle.
    func testEditorOpensFromHero() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: uiTimeout), "no main window")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).doubleClick()
        Thread.sleep(forTimeInterval: 4)

        let editToggle = app.buttons["Edit"]
        guard editToggle.waitForExistence(timeout: 10) else {
            snap("09-editor-no-toggle")
            XCTFail("hero viewer has no 'Edit' toggle")
            return
        }
        editToggle.click()
        Thread.sleep(forTimeInterval: 5)
        snap("09-editor-open")
        dumpTree("editor")

        // The editor is only real if adjustment controls exist. Sliders are the
        // load-bearing evidence — Preview mode has none.
        XCTAssertGreaterThan(app.sliders.count, 0,
                             "Edit mode published no sliders — the editor did not open")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 3)
        snap("09-editor-closed")
    }

    // MARK: - Compare / cull (Spec 03)

    /// Compare needs a MULTI-selection, so this also exercises cmd-click
    /// multi-select in the grid (P10) on the way.
    func testCompareSideBySideOpens() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: uiTimeout), "no main window")
        // Plain-click the first tile, then CMD-click a DIFFERENT one to extend.
        // Getting this wrong is easy and silent: cmd-clicking the tile that is
        // already selected toggles it back off, which is how the first version
        // of this test ended with an empty selection and blamed the app.
        // Coordinates measured from a real screenshot at tile CENTRES. A masonry
        // grid has ragged gaps between tiles, and a click that lands in one
        // clears the selection instead of extending it — which is what made an
        // earlier version of this test report a false "Compare is broken".
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.24)).click()
        Thread.sleep(forTimeInterval: 1.5)
        XCUIElement.perform(withKeyModifiers: .command) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.59, dy: 0.50)).click()
        }
        Thread.sleep(forTimeInterval: 2)
        snap("10-two-selected")

        guard menu("File", "Compare Side by Side") else {
            snap("10-compare-disabled")
            XCTFail("Compare Side by Side stayed disabled after selecting two tiles")
            return
        }
        Thread.sleep(forTimeInterval: 4)
        snap("10-compare-open")
        dumpTree("compare")
        // "Fit" is the compare workbench's own zoom control — absent from the grid.
        XCTAssertTrue(app.buttons["Fit"].waitForExistence(timeout: 10),
                      "compare workbench did not open (no Fit control)")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.buttons["Fit"].exists,
                       "Escape did not close the compare workbench")
    }

    func testStartCullingOpensAndSurvivesEscape() throws {
        guard menu("File", "Start Culling") else {
            XCTFail("Start Culling was disabled at launch"); return
        }
        Thread.sleep(forTimeInterval: 3)
        snap("04-cull-open")
        dumpTree("cull")
        // The HUD's own controls, not "a window exists".
        XCTAssertTrue(app.buttons["Finish"].exists && app.buttons["Cancel"].exists,
                      "cull HUD did not appear (no Finish/Cancel)")

        // Escape must NOT end a culling session. That is Spec 03 deviation D8,
        // and the reasoning is explicit: a cull pass holds keep/reject marks,
        // so "an accidental Escape/misclick must not silently discard an hour
        // of marking" — the session ends only through Finish or Cancel. An
        // earlier version of this test asserted the opposite and reported the
        // app as broken; this now GUARDS the deviation instead.
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
        snap("04-cull-after-escape")
        XCTAssertTrue(app.buttons["Finish"].exists,
                      "Escape ended the culling session — Spec 03 D8 says only "
                      + "Finish/Cancel may, so marks are never silently discarded")

        // Leave the session the way the design intends.
        app.buttons["Cancel"].click()
        Thread.sleep(forTimeInterval: 2)
        snap("04-cull-closed")
        XCTAssertFalse(app.buttons["Finish"].exists,
                       "Cancel did not end the culling session")
    }

    // MARK: - Duplicates (pre-branch feature, P8)

    func testFindDuplicatesOpensAndCloses() throws {
        guard menu("File", "Find Duplicates in Folder") else { return }
        Thread.sleep(forTimeInterval: 5)
        snap("05-duplicates")
        dumpTree("duplicates")
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10),
                      "duplicates modal did not open (no Close button)")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.buttons["Close"].exists,
                       "Escape did not close the duplicates modal")
    }

    // MARK: - Import surfaces (Spec 06)

    /// The two import entries that open an in-app CARD rather than an
    /// NSOpenPanel. A file panel is a separate process and out of scope here.
    func testImportCardsOpenAndEscapeCloses() throws {
        // The five sources do NOT share a panel prompt — asserting a single
        // "Import" button reported two false failures. `AppState+Import` sets
        // "Import", "Import Here" or "Choose Library" depending on what the
        // panel is asking for, so the expectation is per-source.
        let sources: [(item: String, confirm: String)] = [
            ("Metadata & Lightroom Edits…", "Import"),
            ("Lightroom Presets…", "Import"),
            ("From Google Takeout…", "Import"),
            ("From Apple Photos…", "Import Here"),
            ("From Eagle Library…", "Choose Library"),
        ]
        for (item, confirm) in sources {
            guard menu("File", item, submenu: "Import") else {
                // Disabled is a legitimate state for some sources; record it.
                snap("06-import-disabled-\(item.prefix(12))")
                continue
            }
            Thread.sleep(forTimeInterval: 3)
            snap("06-import-\(item.prefix(12))")
            XCTAssertTrue(app.buttons[confirm].waitForExistence(timeout: 10),
                          "import '\(item)' opened no panel (no '\(confirm)' button)")
            dumpTree("import-\(item.prefix(10).replacingOccurrences(of: " ", with: "_"))")
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 2)
            XCTAssertFalse(app.buttons[confirm].exists,
                           "Escape did not dismiss import '\(item)'")
        }
    }

    // MARK: - Backup (Spec 09 / P19)

    /// Opens the backup wizard only. It does NOT run a backup and never touches
    /// Restore — that path rewrites library rows.
    func testBackupWizardOpensAndEscapeCloses() throws {
        guard menu("Muse", "Back Up Muse…") else { return }
        Thread.sleep(forTimeInterval: 3)
        snap("07-backup-wizard")
        dumpTree("backup")
        // Backup presents an NSSavePanel. It belongs to the app, so its Save
        // button is reachable; asserting on it proves the panel, not the window.
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10),
                      "backup save panel did not appear")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.buttons["Save"].exists,
                       "Escape did not dismiss the backup save panel")
    }

    // MARK: - Settings

    func testSettingsOpensAndCloses() throws {
        guard menu("Muse", "Settings…") else { return }
        Thread.sleep(forTimeInterval: 3)
        snap("08-settings")
        dumpTree("settings")
        XCTAssertTrue(app.staticTexts["Automatic organization"].exists
                      || app.checkBoxes["Automatic organization"].exists,
                      "settings did not open (no 'Automatic organization' control)")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.staticTexts["Automatic organization"].exists,
                       "Escape did not close Settings")
    }
}
