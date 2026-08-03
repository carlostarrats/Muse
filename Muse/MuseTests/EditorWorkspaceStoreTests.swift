//
//  EditorWorkspaceStoreTests.swift
//  MuseTests
//
//  Persistence round-trip and the reorder draft's commit/cancel discipline.
//  Leaving reorder mode by ANY route other than Save is a cancel — a
//  half-finished arrangement must never be committed by the user closing the
//  viewer.
//

import XCTest
@testable import Muse

@MainActor
final class EditorWorkspaceStoreTests: XCTestCase {

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: AppSettings.editorWorkspaceKey)
        EditorWorkspaceStore.shared.reloadForTesting()
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: AppSettings.editorWorkspaceKey)
        EditorWorkspaceStore.shared.reloadForTesting()
    }

    // MARK: - AppSettings

    func testUnsetPreferenceReadsAsTheStandardWorkspace() {
        XCTAssertEqual(AppSettings.editorWorkspace, .standard)
    }

    func testWorkspaceRoundTripsThroughPreferences() {
        var w = EditorWorkspace.standard
        w.move(.crop, toColumn: .left, visibleSlot: 0)
        w.setHidden(.splitTone, true)
        AppSettings.editorWorkspace = w
        XCTAssertEqual(AppSettings.editorWorkspace, w)
    }

    func testMalformedPreferenceFallsBackToStandard() {
        UserDefaults.standard.set(Data("not json".utf8),
                                  forKey: AppSettings.editorWorkspaceKey)
        XCTAssertEqual(AppSettings.editorWorkspace, .standard)
    }

    func testPreferenceOfTheWrongTypeFallsBackToStandard() {
        UserDefaults.standard.set(42, forKey: AppSettings.editorWorkspaceKey)
        XCTAssertEqual(AppSettings.editorWorkspace, .standard)
    }

    // MARK: - Store

    func testStoreStartsFromPreferences() {
        var w = EditorWorkspace.standard
        w.setHidden(.effects, true)
        AppSettings.editorWorkspace = w
        EditorWorkspaceStore.shared.reloadForTesting()
        XCTAssertTrue(EditorWorkspaceStore.shared.workspace.hidden.contains(.effects))
    }

    func testSetHiddenPersistsImmediately() {
        // Customize applies LIVE — no OK button — so a checkbox write must
        // survive a relaunch on its own.
        EditorWorkspaceStore.shared.setHidden(.zones, true)
        XCTAssertTrue(AppSettings.editorWorkspace.hidden.contains(.zones))
    }

    func testResetToDefaultClearsLayoutAndVisibility() {
        let store = EditorWorkspaceStore.shared
        store.setHidden(.zones, true)
        store.beginReorder()
        var d = store.reorderDraft!
        d.moveAll(to: .right)
        store.updateDraft(d)
        store.saveReorder()

        store.resetToDefault()
        XCTAssertEqual(store.workspace, .standard)
        XCTAssertEqual(AppSettings.editorWorkspace, .standard)
    }

    // MARK: - Reorder draft

    func testBeginReorderCopiesTheCommittedWorkspace() {
        let store = EditorWorkspaceStore.shared
        store.beginReorder()
        XCTAssertTrue(store.reorderMode)
        XCTAssertEqual(store.reorderDraft, store.workspace)
    }

    func testDraftEditsDoNotTouchTheCommittedWorkspace() {
        let store = EditorWorkspaceStore.shared
        store.beginReorder()
        var d = store.reorderDraft!
        d.moveAll(to: .right)
        store.updateDraft(d)
        XCTAssertEqual(store.workspace, .standard)
        XCTAssertEqual(AppSettings.editorWorkspace, .standard)
    }

    func testSaveCommitsAndPersists() {
        let store = EditorWorkspaceStore.shared
        store.beginReorder()
        var d = store.reorderDraft!
        d.moveAll(to: .right)
        store.updateDraft(d)
        store.saveReorder()
        XCTAssertFalse(store.reorderMode)
        XCTAssertTrue(store.workspace.left.isEmpty)
        XCTAssertTrue(AppSettings.editorWorkspace.left.isEmpty)
    }

    func testCancelRestoresTheEntryWorkspaceExactly() {
        let store = EditorWorkspaceStore.shared
        let entry = store.workspace
        store.beginReorder()
        var d = store.reorderDraft!
        d.moveAll(to: .right)
        store.updateDraft(d)
        store.cancelReorder()
        XCTAssertFalse(store.reorderMode)
        XCTAssertNil(store.reorderDraft)
        XCTAssertEqual(store.workspace, entry)
    }

    func testResetDraftRestoresOrderButLeavesHiddenAlone() {
        // Reorder owns order and sides; Customize owns visibility. The
        // floating bar's Reset must not reach across that line.
        let store = EditorWorkspaceStore.shared
        store.setHidden(.zones, true)
        store.beginReorder()
        var d = store.reorderDraft!
        d.moveAll(to: .right)
        store.updateDraft(d)
        store.resetDraft()
        XCTAssertEqual(store.reorderDraft?.left, EditorWorkspace.standard.left)
        XCTAssertEqual(store.reorderDraft?.right, EditorWorkspace.standard.right)
        XCTAssertEqual(store.reorderDraft?.hidden, [.zones])
    }

    func testCancelUndoesAResetInsideTheMode() {
        let store = EditorWorkspaceStore.shared
        store.beginReorder()
        var d = store.reorderDraft!
        d.moveAll(to: .right)
        store.updateDraft(d)
        store.saveReorder()
        let entry = store.workspace

        store.beginReorder()
        store.resetDraft()
        store.cancelReorder()
        XCTAssertEqual(store.workspace, entry)
    }

    func testActiveIsTheDraftWhileReorderingAndTheWorkspaceOtherwise() {
        let store = EditorWorkspaceStore.shared
        XCTAssertEqual(store.active, store.workspace)
        store.beginReorder()
        var d = store.reorderDraft!
        d.moveAll(to: .right)
        store.updateDraft(d)
        XCTAssertEqual(store.active, d)
        store.cancelReorder()
        XCTAssertEqual(store.active, store.workspace)
    }

    func testEditorDismissedCancelsAnInFlightReorder() {
        // Leaving the mode by any route other than Save is a cancel.
        let store = EditorWorkspaceStore.shared
        let entry = store.workspace
        store.beginReorder()
        var d = store.reorderDraft!
        d.moveAll(to: .right)
        store.updateDraft(d)
        store.editorDismissed()
        XCTAssertFalse(store.reorderMode)
        XCTAssertEqual(store.workspace, entry)
    }

    func testEditorDismissedClosesTheCustomizeModal() {
        let store = EditorWorkspaceStore.shared
        store.customizeShown = true
        store.editorDismissed()
        XCTAssertFalse(store.customizeShown)
    }

    func testBeginReorderClosesTheCustomizeModal() {
        // The two surfaces are never up at once — the menu disables during
        // reorder, but the store enforces it rather than trusting the menu.
        let store = EditorWorkspaceStore.shared
        store.customizeShown = true
        store.beginReorder()
        XCTAssertFalse(store.customizeShown)
    }

    func testUpdateDraftOutsideTheModeIsIgnored() {
        let store = EditorWorkspaceStore.shared
        var w = EditorWorkspace.standard
        w.moveAll(to: .right)
        store.updateDraft(w)
        XCTAssertNil(store.reorderDraft)
        XCTAssertEqual(store.workspace, .standard)
    }
}
