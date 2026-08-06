//
//  MuseWelcomeOnboardingTests.swift
//  MuseUITests
//
//  One narrow drive test for the behavior automation proves better than a
//  person: first-launch presentation persists across a real relaunch.
//

import XCTest

final class MuseWelcomeOnboardingTests: XCTestCase {
    private let uiTimeout: TimeInterval = 30
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        SingleInstanceGuard.assertNoOtherInstance()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testAutomaticWelcomeAppearsOnlyOnce() {
        let suiteName = "com.tarrats.Muse.UITests.welcome.\(UUID().uuidString)"

        app = launch(defaultsSuite: suiteName)
        guard let app else { return XCTFail("application was not created") }

        let firstTitle = element(labeled: "Welcome to Muse. Page 1 of 3.", in: app)
        XCTAssertTrue(firstTitle.waitForExistence(timeout: uiTimeout),
                      "automatic welcome did not appear")

        XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssertTrue(element(labeled: "More ways to organize. Page 2 of 3.", in: app)
            .waitForExistence(timeout: 5))
        app.buttons["Next"].click()
        XCTAssertTrue(element(labeled: "Save and share collections. Page 3 of 3.", in: app)
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Get Started"].waitForExistence(timeout: 5))
        app.buttons["Get Started"].click()

        let emptyState = app.buttons["Add Folder"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 10),
                      "welcome did not dismiss into the empty library")
        XCTAssertFalse(firstTitle.exists)

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))

        let relaunched = launch(defaultsSuite: suiteName)
        self.app = relaunched
        XCTAssertTrue(relaunched.buttons["Add Folder"].waitForExistence(timeout: uiTimeout),
                      "empty-library action did not appear after relaunch")
        XCTAssertFalse(element(labeled: "Welcome to Muse. Page 1 of 3.", in: relaunched)
            .waitForExistence(timeout: 2),
                       "welcome reappeared after completion")
    }

    private func launch(defaultsSuite: String) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments += [
            "--welcome-defaults-suite", defaultsSuite,
            "--welcome-empty-stored-folders"
        ]
        application.launch()
        XCTAssertTrue(application.wait(for: .runningForeground, timeout: uiTimeout),
                      "app never reached runningForeground")
        // macOS can restore a terminated test app with only its menu bar and
        // no document window. The feature under test lives in WindowGroup's
        // content, so create the standard window when restoration supplies
        // none; the semantic assertions below still prove the actual flow.
        if !application.awaitMainWindow(2).exists {
            application.typeKey("n", modifierFlags: .command)
        }
        return application
    }

    private func element(labeled label: String,
                         in application: XCUIApplication) -> XCUIElement {
        application.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }
}
