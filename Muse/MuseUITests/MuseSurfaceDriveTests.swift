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
        // Pin the editor's PERSISTED layout for the run.
        //
        // Which panel cards are open is a global preference, so a test that
        // opens or closes one changes the starting point of every test after
        // it — these passed alone and failed in sequence, in a different place
        // each time. NSUserDefaults reads `-key value` launch arguments as its
        // highest-priority domain, so this fixes the layout without a
        // test-only code path in the app, and without touching the developer's
        // real preferences.
        app.launchArguments += [
            "-editorExpandedSections2", "(tools,histogram,info,light,color)",
            "-editorStylesOpen", "(presets,luts)",
            "-editorBackdrop", "mid",
        ]
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

    /// Click an element by its own centre coordinate. Needed for anything
    /// inside a transparent SwiftUI ScrollView, where XCUITest's hit-point
    /// resolution fails even though the control is perfectly clickable.
    private func hit(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
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
        // The sidebar's FOLDERS header is the cheapest proof the shell came up:
        // it renders only once AppState has published root nodes, which means
        // the DB opened and the migrations ran. (A bare "the window exists"
        // assertion would pass while the app did nothing.)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: uiTimeout), "no main window")
        XCTAssertTrue(app.staticTexts["FOLDERS"].waitForExistence(timeout: uiTimeout),
                      "sidebar did not render — DB or AppState did not publish")
        snap("01-launch")
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

    /// Edit mode's own chrome row: the zoom pill actually zooms the canvas
    /// (before this the editor could only ever show a fitted image), and the
    /// eye hides every control including the hero's Preview | Edit switch.
    func testEditorZoomAndHideControls() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: uiTimeout), "no main window")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).doubleClick()
        Thread.sleep(forTimeInterval: 4)

        let editToggle = app.buttons["Edit"]
        guard editToggle.waitForExistence(timeout: 10) else {
            XCTFail("hero viewer has no 'Edit' toggle"); return
        }
        editToggle.click()
        Thread.sleep(forTimeInterval: 5)

        let zoomIn = app.buttons["Zoom in"]
        XCTAssertTrue(zoomIn.waitForExistence(timeout: 10), "Edit mode published no zoom control")
        // Coordinate clicks, not `.click()`: Edit's chrome rides INSIDE the
        // panel's ScrollView (so it scrolls with the cards, as Preview's does),
        // and XCUITest refuses to resolve a hit point through a scroll view
        // with a transparent background. A real click lands fine.
        hit(zoomIn); hit(zoomIn)
        Thread.sleep(forTimeInterval: 1)
        snap("09b-editor-zoomed")
        // Fit only appears once the canvas is actually off its fitted scale.
        XCTAssertTrue(app.buttons["Fit"].exists,
                      "zooming published no Fit button — the zoom didn't take")

        // Drag-to-pan. There is no queryable "pan" value, so the evidence is
        // the pixels: the canvas is an MTKView behind an NSViewRepresentable,
        // and a SwiftUI drag gesture on one of those is exactly the kind of
        // thing that silently never fires.
        let before = app.screenshot().pngRepresentation
        let canvas = window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        canvas.press(forDuration: 0.2,
                     thenDragTo: window.coordinate(withNormalizedOffset:
                        CGVector(dx: 0.35, dy: 0.42)))
        Thread.sleep(forTimeInterval: 1)
        snap("09d-editor-panned")
        XCTAssertNotEqual(before, app.screenshot().pngRepresentation,
                          "dragging a zoomed canvas changed nothing — pan never fired")

        let hide = app.buttons["Hide controls"]
        XCTAssertTrue(hide.exists, "Edit mode published no hide-controls button")
        hit(hide)
        Thread.sleep(forTimeInterval: 1)
        snap("09c-editor-ui-hidden")
        XCTAssertFalse(app.buttons["Edit"].exists,
                       "hiding the controls left the Preview | Edit switch on screen")
        // NOT a slider count: the main window's grid-spacing slider lives in
        // the same window and stays in the tree behind the viewer.
        XCTAssertFalse(app.buttons["Reset All Adjustments"].exists,
                       "hiding the controls left the panels on screen")

        // And back: the eye stays reachable, or this is a one-way door.
        let show = app.buttons["Show controls"]
        XCTAssertTrue(show.exists, "no way back from hidden controls")
        hit(show)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.buttons["Reset All Adjustments"].exists, "controls never came back")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
    }

    /// The editor's name prompt must be VISIBLE. Regression test for a
    /// layering bug, not a feature demo: the prompt was presented with the
    /// shell's other modals, which are attached to the split view — and the
    /// hero viewer's overlay draws on top of that, so "Save as Version…"
    /// opened its card BEHIND the editor and read as the button doing nothing.
    ///
    /// It stops at CANCEL on purpose. This suite is non-destructive and runs
    /// against the developer's real library; committing would leave a version
    /// row behind, and the delete affordance is hover-only. The save itself was
    /// confirmed by screenshot when the bug was fixed (2026-08-01).
    func testEditorNamePromptOpensAboveTheEditor() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: uiTimeout), "no main window")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).doubleClick()
        Thread.sleep(forTimeInterval: 4)
        let editToggle = app.buttons["Edit"]
        guard editToggle.waitForExistence(timeout: 10) else {
            XCTFail("hero viewer has no 'Edit' toggle"); return
        }
        editToggle.click()
        Thread.sleep(forTimeInterval: 5)

        // HISTORY is the LAST card in the left panel, so it starts below the
        // fold — and an element that exists off-screen still answers `exists`,
        // which is how this test previously clicked into empty space. Collapse
        // the cards above it first so it's really on screen.
        for card in ["TOOLS", "HISTOGRAM", "INFO"] where app.staticTexts[card].exists {
            hit(app.staticTexts[card])
            Thread.sleep(forTimeInterval: 0.4)
        }
        let heading = app.staticTexts["HISTORY"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "no HISTORY card")
        // Open/closed PERSISTS, so this can't assume either state.
        if !app.buttons["Save a snapshot"].exists {
            hit(heading)
            Thread.sleep(forTimeInterval: 1)
        }

        // One list, one Save — "versions" and "snapshots" were the same record
        // under two names and collapsed into snapshots.
        let save = app.buttons["Save a snapshot"]
        if !save.waitForExistence(timeout: 5) {
            dumpTree("history-missing-save")
            snap("09-history-missing-save")
        }
        XCTAssertTrue(save.exists, "History has no Save control: "
                      + buttonLabels().sorted().joined(separator: ", "))
        hit(save)
        Thread.sleep(forTimeInterval: 2)
        snap("09e-version-prompt")

        // The prompt's own title, not "a text field exists" — the main window
        // has a search field, which made that assertion pass on nothing. And
        // HITTABLE, not merely present: the bug being guarded is a card that
        // renders behind the editor.
        let title = app.staticTexts["Save Snapshot"]
        XCTAssertTrue(title.waitForExistence(timeout: 5),
                      "the name prompt never appeared (presented behind the editor?)")
        XCTAssertTrue(title.isHittable,
                      "the name prompt is on screen but unreachable — something is over it")

        // Escape, not the Cancel button: the modal's own buttons resolve
        // inconsistently through XCUITest, and Escape is the path this suite
        // already guards everywhere else.
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.staticTexts["Save Snapshot"].exists, "Escape left the prompt up")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
    }

    /// Side by Side has to actually draw TWO images. It shipped as captions
    /// only — "Before" and "After" floating over one unchanged canvas — which
    /// is why it read as a toggle that does nothing.
    func testSideBySideDrawsTwoImages() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: uiTimeout), "no main window")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).doubleClick()
        Thread.sleep(forTimeInterval: 4)
        let editToggle = app.buttons["Edit"]
        guard editToggle.waitForExistence(timeout: 10) else {
            XCTFail("hero viewer has no 'Edit' toggle"); return
        }
        editToggle.click()
        Thread.sleep(forTimeInterval: 5)

        let before = app.screenshot().pngRepresentation
        let sideBySide = app.buttons["Side by Side"]
        XCTAssertTrue(sideBySide.waitForExistence(timeout: 10), "no Side by Side control")
        hit(sideBySide)
        Thread.sleep(forTimeInterval: 2)
        snap("09g-side-by-side")

        XCTAssertTrue(app.staticTexts["Before"].exists && app.staticTexts["After"].exists,
                      "the two captions are missing")
        // The canvas is an MTKView, so the pixels are the only evidence that
        // the mode did anything at all.
        XCTAssertNotEqual(before, app.screenshot().pngRepresentation,
                          "Side by Side changed nothing on the canvas")

        hit(sideBySide)   // back off
        Thread.sleep(forTimeInterval: 1)
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
    }

    /// The Styles browser: its sections collapse, it switches between grid and
    /// list, and "Original" exists as a thing you can pick.
    func testStylesBrowserModesAndOriginal() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: uiTimeout), "no main window")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).doubleClick()
        Thread.sleep(forTimeInterval: 4)
        let editToggle = app.buttons["Edit"]
        guard editToggle.waitForExistence(timeout: 10) else {
            XCTFail("hero viewer has no 'Edit' toggle"); return
        }
        editToggle.click()
        Thread.sleep(forTimeInterval: 5)

        // The card's open/closed state PERSISTS, so this can't assume either
        // one — tap the heading until the browser is actually showing.
        let heading = app.staticTexts["STYLES"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "no STYLES card")
        if !app.buttons["Grid"].exists {
            hit(heading)
            Thread.sleep(forTimeInterval: 1.5)
        }
        snap("09h-styles-grid")

        for control in ["Grid", "List", "Presets", "LUTs"] {
            XCTAssertTrue(app.buttons[control].exists, "Styles has no \(control) control")
        }
        // "Original" is only meaningful when there is something to opt out of,
        // so it's asserted per section only when that section has content.
        hit(app.buttons["List"])
        Thread.sleep(forTimeInterval: 1.5)
        snap("09i-styles-list")
        // The mode has to actually CHANGE — the argument domain outranks a
        // defaults write, so pinning this key made the button a no-op and the
        // "list" screenshot was still a grid.
        XCTAssertTrue(app.buttons["List"].isSelected, "the List button didn't take")

        // Collapsing a section must keep saying what's selected.
        hit(app.buttons["Presets"])
        Thread.sleep(forTimeInterval: 1)
        snap("09j-styles-collapsed")
        XCTAssertEqual(app.buttons["Presets"].value as? String, "Original",
                       "a collapsed section stopped reporting its selection")

        hit(app.buttons["Grid"])
        Thread.sleep(forTimeInterval: 1)
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
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
