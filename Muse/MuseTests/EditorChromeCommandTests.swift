//
//  EditorChromeCommandTests.swift
//  MuseTests
//
//  The View menu's hide-UI item reads this singleton for BOTH its enabled state
//  and its title, so the two states that matter are "no editor on screen"
//  (nil → disabled) and "editor on screen, hidden or not" (title). A stale
//  mirror is the failure mode: an item that stays enabled after the viewer
//  closes, or one whose title says Hide while the UI is already hidden.
//

import XCTest
@testable import Muse

@MainActor
final class EditorChromeCommandTests: XCTestCase {

    /// Shared app-wide state, so each test leaves it as it found it.
    override func tearDown() async throws {
        EditorChromeCommand.shared.editorDismissed()
    }

    func testMirrorIsNilWithNoEditorOnScreen() {
        let command = EditorChromeCommand.shared
        command.editorPresented(uiHidden: true)
        command.editorDismissed()
        XCTAssertNil(command.uiHidden, "the menu item would stay enabled with no editor open")
    }

    func testMirrorFollowsTheEditorsState() {
        let command = EditorChromeCommand.shared
        command.editorPresented(uiHidden: false)
        XCTAssertEqual(command.uiHidden, false)
        // The editor re-publishes on every change of its own flag, including
        // the ones a click on the eye makes — the menu title has to follow a
        // toggle it didn't initiate.
        command.editorPresented(uiHidden: true)
        XCTAssertEqual(command.uiHidden, true)
    }

    /// The menu bumps a counter rather than assigning `uiHidden`: the editor
    /// owns the animated toggle, and only a CHANGE in this value triggers it.
    func testEachRequestIsADistinctValue() {
        let command = EditorChromeCommand.shared
        let start = command.toggleRequests
        command.requestToggle()
        command.requestToggle()
        XCTAssertEqual(command.toggleRequests, start + 2,
                       "two presses that publish one value would toggle only once")
    }
}
