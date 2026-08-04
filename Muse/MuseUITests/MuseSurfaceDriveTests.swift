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
            "-editorExpandedSections2", "(tools,histogram,insights,light,color)",
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
        // The TILE, not a window fraction — see `firstPhotoTile`. A fraction is
        // aimed by whatever size the window was restored at.
        guard openPhoto(in: app, doubleClick: false, settle: 1.5) else { return }
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
        guard openPhoto(in: app) else { return }
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
        guard openPhoto(in: app) else { return }

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
        guard openPhoto(in: app) else { return }

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

        // ⌘U is the same toggle from the keyboard, which is the whole point of
        // it — hiding the UI is a there-and-back move and reaching for the
        // button each way defeats it. The shortcut rides the eye BUTTON, and
        // that button is in a different place in each state, so both
        // directions have to be driven.
        app.typeKey("u", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)
        snap("09e-editor-ui-hidden-by-key")
        XCTAssertFalse(app.buttons["Reset All Adjustments"].exists,
                       "⌘U did not hide the controls")
        app.typeKey("u", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.buttons["Reset All Adjustments"].exists,
                      "⌘U did not bring the controls back")

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
        guard openPhoto(in: app) else { return }
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
        for card in ["TOOLS", "HISTOGRAM", "INSIGHTS"] where app.staticTexts[card].exists {
            hit(app.staticTexts[card])
            Thread.sleep(forTimeInterval: 0.4)
        }
        let heading = app.staticTexts["SNAPSHOTS"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "no SNAPSHOTS card")
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
        guard openPhoto(in: app) else { return }
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
        guard openPhoto(in: app) else { return }
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

    // MARK: - Compare (Spec 03)

    /// Compare needs a MULTI-selection, so this also exercises cmd-click
    /// multi-select in the grid (P10) on the way.
    func testCompareSideBySideOpens() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: uiTimeout), "no main window")
        // Plain-click the first tile, then CMD-click a DIFFERENT one to extend.
        // Getting this wrong is easy and silent: cmd-clicking the tile that is
        // already selected toggles it back off, which is how the first version
        // of this test ended with an empty selection and blamed the app.
        //
        // The tiles are LOCATED, never computed. This test used two window
        // fractions "measured from a real screenshot" — the exact pattern round
        // 9 removed everywhere else and this one kept. macOS persists the window
        // frame, so the moment the window was a different size those fractions
        // aimed somewhere else; it duly failed reporting "Compare is broken"
        // when compare was fine. Round 12 found it that way.
        let tiles = app.photoTiles(limit: 2)
        guard tiles.count == 2 else {
            XCTFail("need two photo tiles in the grid, found \(tiles.count)")
            return
        }
        tiles[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        Thread.sleep(forTimeInterval: 1.5)
        XCUIElement.perform(withKeyModifiers: .command) {
            tiles[1].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
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

    // MARK: - Editor workspace (Polish 33)

    /// Opens the editor and returns once its sliders are published, or fails.
    /// Every workspace test needs the same three steps first.
    @discardableResult
    private func openEditor() -> Bool {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: uiTimeout), "no main window")
        guard openPhoto(in: app) else { return false }
        let editToggle = app.buttons["Edit"]
        guard editToggle.waitForExistence(timeout: 10) else {
            XCTFail("hero viewer has no 'Edit' toggle")
            return false
        }
        editToggle.click()
        Thread.sleep(forTimeInterval: 5)
        guard app.sliders.count > 0 else {
            snap("20-editor-did-not-open")
            XCTFail("Edit mode published no sliders — the editor did not open")
            return false
        }
        return true
    }

    /// Leave the editor and the viewer, whatever state they are in, so one
    /// test's mode cannot leak into the next.
    private func closeEditor() {
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
    }

    /// The submenu exists, and every item is DISABLED outside Edit mode — the
    /// same contextual gate the hide-UI item uses.
    func testEditorWorkspaceMenuIsOffOutsideTheEditor() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: uiTimeout), "no main window")

        app.menuBars.menuBarItems["View"].click()
        let submenu = app.menuBars.menuItems["Editor Workspace"]
        XCTAssertTrue(submenu.waitForExistence(timeout: 5),
                      "View menu has no 'Editor Workspace' submenu")

        // Assert on the CHILDREN, not the submenu's parent item. AppKit reports
        // a parent that owns a submenu as enabled whatever SwiftUI's
        // `.disabled()` says — the disabling lands on the items inside. The
        // first version of this test checked the parent and failed against a
        // perfectly correct menu. `Hide controls` is the control: a plain
        // Button under the same condition, which DOES report disabled.
        XCTAssertFalse(app.menuBars.menuItems["Hide controls"].isEnabled,
                       "the control item is enabled with no editor — "
                       + "this test's premise is wrong, not the workspace menu")
        submenu.hover()
        for item in ["Default Layout", "Customize Modules…", "Reorder Modules"] {
            let element = app.menuBars.menuItems[item]
            XCTAssertTrue(element.waitForExistence(timeout: 5), "'\(item)' is missing")
            XCTAssertFalse(element.isEnabled,
                           "'\(item)' is live with no editor on screen")
        }
        snap("20-workspace-menu-disabled")
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Customize Modules opens, applies LIVE, and Escape closes it.
    ///
    /// The live-apply assertion is the load-bearing one: unchecking a box has
    /// to remove that card from the panel BEHIND the open modal, with no OK
    /// button anywhere in the flow.
    func testCustomizeModulesHidesACardLive() throws {
        guard openEditor() else { return }
        defer { closeEditor() }

        XCTAssertTrue(app.staticTexts["SPLIT TONE"].exists,
                      "SPLIT TONE is not on the panel to begin with")

        guard menu("View", "Customize Modules…", submenu: "Editor Workspace") else {
            XCTFail("Customize Modules… was not reachable")
            return
        }
        Thread.sleep(forTimeInterval: 2)
        snap("21-customize-open")

        let box = app.checkBoxes["SPLIT TONE"]
        XCTAssertTrue(box.waitForExistence(timeout: 5),
                      "the Customize list has no SPLIT TONE row")
        box.click()
        Thread.sleep(forTimeInterval: 1.5)
        // The checkbox itself must have flipped. Without this, a click that
        // lands on nothing looks identical to a click that worked until the
        // panel assertion below — and that is exactly how the card-behind-the-
        // editor bug hid.
        XCTAssertEqual(box.value as? Int, 0, "the checkbox did not change state")
        snap("21-customize-unchecked")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.checkBoxes["SPLIT TONE"].exists, "Escape did not close Customize")
        XCTAssertFalse(app.staticTexts["SPLIT TONE"].exists,
                       "unchecking did not remove the card from the panel")
        snap("21-card-gone")

        // Put it back, so the persisted workspace does not leak into the next
        // test — this preference survives relaunch by design.
        guard menu("View", "Customize Modules…", submenu: "Editor Workspace") else { return }
        Thread.sleep(forTimeInterval: 2)
        app.checkBoxes["SPLIT TONE"].click()
        Thread.sleep(forTimeInterval: 1)
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(app.staticTexts["SPLIT TONE"].exists, "re-checking did not restore the card")
    }

    /// The Customize card must not CLIP its content.
    ///
    /// It shipped with no padding at all: the presenter sizes a card to
    /// whatever its content reports, so a card that asks to be exactly as tall
    /// as its rows gets exactly that, and the title sat against the top edge
    /// with the bottom row against the bottom. Owner caught it on screen.
    ///
    /// This guard was PROVEN by removing `.padding(28)` and watching it go red
    /// on every side — which matters, because its first version compared the
    /// last row to the WINDOW (hundreds of points taller than the card) and
    /// would have passed on the bug it was written for.
    ///
    /// It does NOT resize the window, deliberately, on two counts. The padding
    /// is a constant and cannot vary with window height; and the card can never
    /// reach the presenter's scroll cap anyway — that cap at the app's 480pt
    /// minimum window is 432pt and twelve rows plus the heading come to about
    /// 411. An earlier version DID resize, to check scrolling, and it (a)
    /// asserted a scroll that never happened, and (b) left the window shrunk
    /// when it failed, which then broke `testCompareSideBySideOpens` two tests
    /// later. macOS persists window frames between runs; a drive test must not
    /// mutate global UI state it cannot reliably put back. If the module list
    /// ever passes ~13 rows, scrolling becomes reachable and needs a real check.
    func testCustomizeCardDoesNotClipItsLastRow() throws {
        guard openEditor() else { return }
        defer { closeEditor() }

        guard menu("View", "Customize Modules…", submenu: "Editor Workspace") else {
            XCTFail("Customize Modules… was not reachable")
            return
        }
        Thread.sleep(forTimeInterval: 2)
        snap("24-customize-card")
        assertNoRowIsClipped(context: "in the Customize card")
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Every module row present, reachable, and clear of the CARD's edges.
    ///
    /// Measured against the card, not the window. The first version of this
    /// compared the last row to `app.windows.firstMatch` — which is hundreds of
    /// points taller than the card, so it would have PASSED on the very bug it
    /// was written to catch. The card publishes its own frame: the presenter
    /// wraps content in a ScrollView, so that element IS the card's rect.
    private func assertNoRowIsClipped(context: String,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        for module in EditorModuleTitles.all {
            let box = app.checkBoxes[module]
            XCTAssertTrue(box.exists, "'\(module)' row is missing \(context)",
                          file: file, line: line)
            XCTAssertTrue(box.isHittable, "'\(module)' row is not reachable \(context)",
                          file: file, line: line)
        }

        let first = app.checkBoxes[EditorModuleTitles.all.first!]
        let last = app.checkBoxes[EditorModuleTitles.all.last!]
        let title = app.staticTexts["Customize Modules"]
        // The card, found as the scroller that CONTAINS the list rather than by
        // index — the editor's own panels are scroll views too.
        var card: CGRect?
        for i in 0..<app.scrollViews.count {
            let f = app.scrollViews.element(boundBy: i).frame
            if f.contains(first.frame.origin) { card = f; break }
        }
        guard let card else {
            XCTFail("could not find the card's frame \(context)", file: file, line: line)
            return
        }

        // A card with no padding has its content flush on every side — that is
        // exactly what shipped. 20pt is comfortably under the real 28 and
        // comfortably over the 0 the bug produced.
        let minimumInset: CGFloat = 20
        XCTAssertGreaterThan(title.frame.minY - card.minY, minimumInset,
                             "the title is flush with the card's top edge \(context)",
                             file: file, line: line)
        XCTAssertGreaterThan(card.maxY - last.frame.maxY, minimumInset,
                             "the last row is flush with the card's bottom edge \(context)",
                             file: file, line: line)
        XCTAssertGreaterThan(first.frame.minX - card.minX, minimumInset,
                             "the rows are flush with the card's left edge \(context)",
                             file: file, line: line)
    }

    /// Reorder mode is a MODE: every card collapses to a bar, so no adjustment
    /// control is reachable, and Escape cancels the mode rather than the viewer.
    ///
    /// The slider count is measured against a BASELINE taken before the editor
    /// opens, not against zero. `app.sliders` is app-wide, and the grid's
    /// "Images per row" toolbar slider is still published behind the viewer —
    /// asserting zero failed against a perfectly collapsed panel.
    func testReorderModeCollapsesEveryCardAndCancelRestores() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: uiTimeout), "no main window")
        let baseline = app.sliders.count

        guard openEditor() else { return }
        defer { closeEditor() }
        let withCards = app.sliders.count
        XCTAssertGreaterThan(withCards, baseline, "the editor published no sliders of its own")

        guard menu("View", "Reorder Modules", submenu: "Editor Workspace") else {
            XCTFail("Reorder Modules was not reachable")
            return
        }
        Thread.sleep(forTimeInterval: 2.5)
        snap("22-reorder-mode")

        XCTAssertEqual(app.sliders.count, baseline,
                       "reorder mode left editor sliders reachable — cards did not collapse")
        XCTAssertTrue(app.buttons["Save"].exists, "no Save in the floating bar")
        XCTAssertTrue(app.buttons["Cancel"].exists, "no Cancel in the floating bar")
        XCTAssertTrue(app.buttons["All Left"].exists, "no All Left in the floating bar")
        XCTAssertTrue(app.buttons["All Right"].exists, "no All Right in the floating bar")

        // ONE Escape, with no menu open to swallow it. This is the branch that
        // resolves above `.closeHero`: it must cancel the MODE and leave the
        // viewer standing. If it closed the viewer instead, the cards do not
        // come back and this fails.
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2.5)
        snap("22-reorder-cancelled")
        XCTAssertFalse(app.buttons["Save"].exists, "Escape did not leave reorder mode")
        XCTAssertEqual(app.sliders.count, withCards,
                       "Escape did not restore the cards (or it closed the viewer)")
    }

    /// While a reorder owns the editor, the workspace menu and ⌘U are off.
    ///
    /// Asserted on the submenu's CHILDREN: AppKit reports a parent item that
    /// owns a submenu as enabled whatever SwiftUI's `.disabled()` says.
    func testWorkspaceMenuAndHideControlsAreOffDuringAReorder() throws {
        guard openEditor() else { return }
        defer { closeEditor() }

        guard menu("View", "Reorder Modules", submenu: "Editor Workspace") else { return }
        Thread.sleep(forTimeInterval: 2.5)

        app.menuBars.menuBarItems["View"].click()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(app.menuBars.menuItems["Hide controls"].isEnabled,
                       "⌘U is still live during a reorder")
        app.menuBars.menuItems["Editor Workspace"].hover()
        Thread.sleep(forTimeInterval: 0.8)
        for item in ["Default Layout", "Customize Modules…", "Reorder Modules"] {
            XCTAssertFalse(app.menuBars.menuItems[item].isEnabled,
                           "'\(item)' is still live during a reorder")
        }
        snap("22-menu-off-during-reorder")

        // Two Escapes: the first dismisses the open menu, the second cancels
        // the mode. The menu swallows the first — that off-by-one is what made
        // the first version of this test fail against correct behaviour.
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.buttons["Save"].exists, "still in reorder mode")
    }

    /// All Right empties the left column; Save commits it and the photo gets
    /// that side back. Then Default Layout puts everything home again.
    func testAllRightThenDefaultLayoutRoundTrips() throws {
        guard openEditor() else { return }
        defer { closeEditor() }

        // TOOLS is the left column's first card — its presence is the cheapest
        // proof the left column is drawn at all.
        XCTAssertTrue(app.staticTexts["TOOLS"].exists, "TOOLS missing before the move")

        guard menu("View", "Reorder Modules", submenu: "Editor Workspace") else { return }
        Thread.sleep(forTimeInterval: 2)
        app.buttons["All Right"].click()
        Thread.sleep(forTimeInterval: 1.5)
        snap("23-all-right")
        app.buttons["Save"].click()
        Thread.sleep(forTimeInterval: 3)
        snap("23-single-column")

        // Still present — moved, not lost. This is the assertion that would
        // catch a move that dropped modules on the floor.
        XCTAssertTrue(app.staticTexts["TOOLS"].exists, "TOOLS vanished on All Right")
        XCTAssertTrue(app.staticTexts["CROP & STRAIGHTEN"].exists,
                      "CROP & STRAIGHTEN vanished on All Right")
        XCTAssertGreaterThan(app.sliders.count, 0, "the single column has no controls")

        guard menu("View", "Default Layout", submenu: "Editor Workspace") else {
            XCTFail("Default Layout was not reachable")
            return
        }
        Thread.sleep(forTimeInterval: 3)
        snap("23-back-to-default")
        XCTAssertTrue(app.staticTexts["TOOLS"].exists, "TOOLS missing after Default Layout")
        XCTAssertTrue(app.staticTexts["STYLES"].exists, "STYLES missing after Default Layout")
    }
}

/// The twelve card headings, in default panel order — the labels the Customize
/// list publishes. Kept beside the drive tests rather than read from the app so
/// a rename has to be noticed here too.
enum EditorModuleTitles {
    static let all = ["TOOLS", "HISTOGRAM", "INSIGHTS", "SNAPSHOTS",
                      "STYLES", "LIGHT", "TONE ZONES", "COLOR",
                      "COLOR MIX", "SPLIT TONE", "EFFECTS", "CROP & STRAIGHTEN"]
}
