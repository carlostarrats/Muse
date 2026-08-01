//
//  MuseDriveProbe.swift
//  MuseUITests
//
//  A discovery probe, not an assertion suite. Ledger gap G1 is "nobody has
//  driven the GUI"; the first thing driving it requires is knowing what the
//  accessibility tree actually exposes, since XCUITest can only reach elements
//  AppKit/SwiftUI publish. This dumps the tree so the real tests can be written
//  against what exists rather than what the specs say should exist.
//

import XCTest

final class MuseDriveProbe: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testDumpElementTree() throws {
        let app = XCUIApplication()
        app.launch()

        // The library is large and the grid populates asynchronously; give the
        // first folder load room to publish before snapshotting the tree.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30),
                      "app never reached runningForeground")
        Thread.sleep(forTimeInterval: 8)

        let dump = app.debugDescription
        let attachment = XCTAttachment(string: dump)
        attachment.name = "element-tree"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Also write it somewhere readable without unpacking the .xcresult.
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-element-tree.txt")
        try? dump.write(to: out, atomically: true, encoding: .utf8)
        print("ELEMENT_TREE_PATH: \(out.path)")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "probe-state"
        shot.lifetime = .keepAlways
        add(shot)

        // Counts of the coarse element classes, printed so they land in the
        // xcodebuild log even if attachments are awkward to read.
        print("PROBE windows=\(app.windows.count) buttons=\(app.buttons.count) "
              + "menuBars=\(app.menuBars.count) tables=\(app.tables.count) "
              + "outlines=\(app.outlines.count) images=\(app.images.count) "
              + "textFields=\(app.textFields.count) groups=\(app.groups.count)")
    }
}
