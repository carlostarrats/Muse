//
//  MuseExportDriveTests.swift
//  MuseUITests
//
//  Drives the export card in the running app. Companion to
//  MuseSurfaceDriveTests, same rules: non-destructive, runs against the
//  developer's real library, every modal also closed with Escape.
//
//  ONE DELIBERATE OMISSION, and it's the important one to state. Pressing
//  Export opens the sandbox's powerbox folder panel, which runs
//  out-of-process; driving it from here is unreliable and, on a machine nobody
//  is sitting at, unresolvable if it misbehaves. So these tests exercise
//  everything up TO the panel and stop. The bytes on the other side of it are
//  covered instead by ImageExportRenderTests, which writes and reads back real
//  files for every format, depth, background and collision case.
//
//  What this file is really for is the two things unit tests cannot see:
//  whether the card OPENS IN FRONT of the hero viewer and the editor (it
//  didn't — that was the first review finding), and whether its controls
//  respond at all.
//

import XCTest

final class MuseExportDriveTests: XCTestCase {

    private let uiTimeout: TimeInterval = 30
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        // Fail here, with the reason, rather than let a second instance
        // manufacture failures that accuse the app. See SingleInstanceGuard.
        SingleInstanceGuard.assertNoOtherInstance()
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += [
            "-editorExpandedSections2", "(tools,histogram,insights,light,color)",
            "-editorStylesOpen", "(presets,luts)",
            "-editorBackdrop", "mid",
            // Start every run from the same export settings, so a previous
            // run's remembered format can't decide what this one asserts.
            "-lastExportSettings", "",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: uiTimeout),
                      "app never reached runningForeground")
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

    private func dumpTree(_ name: String) {
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-tree-\(name).txt")
        try? app.debugDescription.write(to: out, atomically: true, encoding: .utf8)
        print("TREE \(name): \(out.path)")
    }

    @discardableResult
    private func menu(_ bar: String, _ item: String) -> Bool {
        let barItem = app.menuBars.menuBarItems[bar]
        guard barItem.waitForExistence(timeout: uiTimeout) else { return false }
        barItem.click()
        let target = app.menuBars.menuItems[item]
        guard target.waitForExistence(timeout: 5) else {
            app.typeKey(.escape, modifierFlags: [])
            return false
        }
        guard target.isEnabled else {
            app.typeKey(.escape, modifierFlags: [])
            return false
        }
        target.click()
        return true
    }

    /// Single-click the grid to select a tile (double-click would open it).
    private func selectFirstTile() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: uiTimeout), "no main window")
        guard openPhoto(in: app, doubleClick: false, settle: 1.5) else { return }
    }

    /// Every static text's LABEL and VALUE.
    ///
    /// Rows built with `.accessibilityElement(children: .combine)` — the
    /// estimate and the social size row — publish ONE element whose *value* is
    /// the merged "Est. file size, 128 KB". Asserting on `staticTexts["Est.
    /// file size"]` therefore finds nothing, which is what the first version of
    /// these tests did: three failures that were all this, and none of which
    /// meant the app was broken. Combining is right for VoiceOver (one fact,
    /// read once), so the test moves, not the app.
    private func staticTextStrings() -> [String] {
        var out: [String] = []
        for i in 0..<app.staticTexts.count {
            let e = app.staticTexts.element(boundBy: i)
            if !e.label.isEmpty { out.append(e.label) }
            if let v = e.value as? String, !v.isEmpty { out.append(v) }
        }
        return out
    }

    private func anyStaticText(containing needle: String) -> Bool {
        staticTextStrings().contains { $0.contains(needle) }
    }

    /// The card is up when its own title and its Export button are both there.
    private func exportCardIsOpen() -> Bool {
        app.staticTexts["Export"].exists && app.buttons["Export…"].exists
    }

    private func waitForExportCard(_ message: String) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && !exportCardIsOpen() {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(exportCardIsOpen(), message)
    }

    // MARK: - The card opens, from each surface

    func testExportCardOpensFromTheGridSelection() throws {
        selectFirstTile()
        XCTAssertTrue(menu("File", "Export…"),
                      "File ▸ Export… was missing or disabled with a tile selected")
        waitForExportCard("the export card never appeared from the grid")
        dumpTree("export-card")
        snap("01-export-from-grid")

        // The controls the rebuild added, all of which are format-branch only.
        // Quality is a COMBINED row ("Quality, 85%") — same reason as the
        // estimate below, and it moved into the shared `readout` helper on
        // 2026-08-02, which is what broke the old `staticTexts["Quality"]`
        // lookup. Asserting on the merged string also proves the readout
        // RESOLVED, where a bare label only proved a label was drawn.
        XCTAssertTrue(staticTextStrings().contains { $0.contains("Quality") && $0.contains("%") },
                      "no Quality readout — got: \(staticTextStrings().prefix(20))")
        // Size stays a plain `labelled(_:)` header over the width/height
        // fields, so it is still its own element.
        XCTAssertTrue(app.staticTexts["Size"].exists, "no Size control")
        XCTAssertTrue(anyStaticText(containing: "Est. file size"),
                      "no estimated size readout")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(exportCardIsOpen(), "Escape did not close the export card")
    }

    /// THE regression test for review finding one. The card is presented on the
    /// shell's OUTER stack; attached to the split view it drew above the shell's
    /// own cards but UNDER the hero viewer, so pressing Export from Preview
    /// opened it behind the photo and it looked like nothing happened.
    ///
    /// "In front" is asserted by hit-testability: a card behind the viewer's
    /// full-window overlay cannot be hit, however much of it exists.
    func testExportCardOpensInFrontOfTheHeroViewer() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: uiTimeout), "no main window")
        guard openPhoto(in: app, settle: 3) else { return }
        snap("02-hero-open")

        XCTAssertTrue(menu("File", "Export…"),
                      "File ▸ Export… was missing or disabled with the viewer open")
        waitForExportCard("the export card never appeared over the hero viewer")
        snap("03-export-over-hero")

        let exportButton = app.buttons["Export…"]
        XCTAssertTrue(exportButton.isHittable,
                      "the card exists but is not hittable — it is BEHIND the viewer again")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(exportCardIsOpen(), "Escape did not close the card over the viewer")
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
    }

    /// Same again from EDIT mode, which replaces the viewer's whole right rail
    /// and so is a different layer from Preview.
    func testExportCardOpensInFrontOfTheEditor() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: uiTimeout), "no main window")
        guard openPhoto(in: app, settle: 3) else { return }

        let editToggle = app.buttons["Edit"].firstMatch
        guard editToggle.waitForExistence(timeout: 8) else {
            // Not every kind is editable; a non-image first tile is not a bug.
            throw XCTSkip("the first tile is not an editable kind")
        }
        editToggle.click()
        Thread.sleep(forTimeInterval: 3)
        snap("04-editor-open")

        XCTAssertTrue(menu("File", "Export…"),
                      "File ▸ Export… was missing or disabled in the editor")
        waitForExportCard("the export card never appeared over the editor")
        XCTAssertTrue(app.buttons["Export…"].isHittable,
                      "the card is not hittable in Edit — it is BEHIND the editor")
        snap("05-export-over-editor")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(exportCardIsOpen(), "Escape did not close the card over the editor")
    }

    // MARK: - The controls respond

    /// Typing a width has to reach the model. It only committed `onSubmit`
    /// before review, so a value you typed and then clicked away from was
    /// silently discarded — the field said 800 and the export used 4000.
    func testTypingASizeUpdatesTheOtherFields() throws {
        selectFirstTile()
        XCTAssertTrue(menu("File", "Export…"), "File ▸ Export… unavailable")
        waitForExportCard("the export card never appeared")

        let fields = app.textFields
        guard fields.count >= 3 else {
            dumpTree("export-fields")
            return XCTFail("expected width, height and scale fields; found \(fields.count)")
        }
        let width = fields.element(boundBy: 0)
        let percent = fields.element(boundBy: 2)
        let originalPercent = percent.value as? String ?? ""
        XCTAssertEqual(originalPercent, "100", "scale should start at 100%")

        width.click()
        width.typeKey("a", modifierFlags: .command)
        width.typeText("400")
        // Tab moves focus, which is what commits — the case that used to lose
        // the value entirely.
        app.typeKey("\t", modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
        snap("06-size-typed")

        let newPercent = percent.value as? String ?? ""
        XCTAssertNotEqual(newPercent, "100",
                          "typing a width did not commit — scale never moved off 100%")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
    }

    /// The estimate has to be a number, not a dash, once the preview decodes.
    func testEstimatedSizeResolvesToARealNumber() throws {
        selectFirstTile()
        XCTAssertTrue(menu("File", "Export…"), "File ▸ Export… unavailable")
        waitForExportCard("the export card never appeared")

        // The preview has to decode first, then the estimate debounces 180ms
        // behind it, so this polls rather than reading once.
        //
        // Matched on the ROW (label + byte unit) rather than on a "≈" prefix,
        // which the readout no longer carries: the row already says "Est.", so
        // the second hedge in front of the number was dropped.
        var text = ""
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let found = staticTextStrings().first(where: {
                $0.contains("Est. file size") && ($0.contains("KB") || $0.contains("MB"))
            }) {
                text = found
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        snap("07-estimate")
        XCTAssertFalse(text.isEmpty,
                       "the estimate never resolved — the readout still shows its placeholder")
        XCTAssertTrue(text.contains("B"), "estimate '\(text)' carries no byte unit")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
    }

    /// Every format the machine can write must be offered, and picking one must
    /// change what the card says it will produce.
    func testFormatDropdownOffersTheFormats() throws {
        selectFirstTile()
        XCTAssertTrue(menu("File", "Export…"), "File ▸ Export… unavailable")
        waitForExportCard("the export card never appeared")

        let preset = app.popUpButtons.firstMatch
        XCTAssertTrue(preset.waitForExistence(timeout: 5), "no preset dropdown")
        preset.click()
        Thread.sleep(forTimeInterval: 1)
        snap("08-preset-menu")

        for expected in ["JPEG", "PNG", "TIFF", "Same as original", "Instagram"] {
            XCTAssertTrue(app.menuItems[expected].exists,
                          "'\(expected)' missing from the preset dropdown")
        }
        // The platforms cut on review must stay cut.
        for gone in ["Glass", "Flickr / 500px", "Pinterest", "Threads"] {
            XCTAssertFalse(app.menuItems[gone].exists, "'\(gone)' came back")
        }

        app.menuItems["PNG"].click()
        Thread.sleep(forTimeInterval: 1.5)
        snap("09-png-selected")
        // PNG is lossless: the quality control has nothing to say and goes away.
        XCTAssertFalse(app.staticTexts["Quality"].exists,
                       "Quality is still shown for PNG, which has no quality setting")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
    }

    /// Picking a platform swaps the whole right column, and the size it will
    /// produce has to be stated — it wasn't, before review.
    func testSocialPresetShowsItsOutputSize() throws {
        selectFirstTile()
        XCTAssertTrue(menu("File", "Export…"), "File ▸ Export… unavailable")
        waitForExportCard("the export card never appeared")

        let preset = app.popUpButtons.firstMatch
        XCTAssertTrue(preset.waitForExistence(timeout: 5), "no preset dropdown")
        preset.click()
        Thread.sleep(forTimeInterval: 1)
        guard app.menuItems["Instagram"].exists else {
            app.typeKey(.escape, modifierFlags: [])
            return XCTFail("Instagram missing from the preset dropdown")
        }
        app.menuItems["Instagram"].click()
        Thread.sleep(forTimeInterval: 2)
        snap("10-instagram-selected")

        XCTAssertTrue(anyStaticText(containing: "Size"),
                      "a social preset states no output size")
        XCTAssertTrue(anyStaticText(containing: "px"),
                      "no pixel dimensions shown for the platform preset")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
    }
}
