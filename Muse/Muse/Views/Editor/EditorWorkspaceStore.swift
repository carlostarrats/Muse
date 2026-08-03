//
//  EditorWorkspaceStore.swift
//  Muse
//
//  The seam between the View menu, the Customize modal, and the editor's
//  panels.
//
//  A Pattern B singleton, exactly like `EditorChromeCommand` and for the same
//  two reasons: the menu bar is built in `MuseApp` while the editor is several
//  layers inside `ContentView`'s viewer overlay, so a command needs somewhere
//  to meet — and a `@Published` on `AppState` re-evaluates the whole
//  `ContentView` body, sidebar and grid included, on every change. `AppState`
//  is frozen (DECIDED #26).
//
//  Reorder is TRANSACTIONAL and the committed workspace is not. Customize
//  applies live (no OK button, so each checkbox persists on its own), while
//  reorder edits a DRAFT that only `saveReorder()` commits. Leaving the mode by
//  any other route — Cancel, Escape, or the viewer closing — discards it. A
//  half-finished arrangement must never be committed by the user closing a
//  photo, and there is deliberately no "save your layout?" prompt on the way
//  out of a photo viewer: the cost of losing a rearrangement is a few seconds
//  of dragging.
//

import SwiftUI

@MainActor
final class EditorWorkspaceStore: ObservableObject {
    static let shared = EditorWorkspaceStore()

    /// The committed layout. Persisted on every write.
    @Published private(set) var workspace: EditorWorkspace

    /// The in-flight arrangement while reorder mode is active; nil otherwise.
    @Published private(set) var reorderDraft: EditorWorkspace?

    /// The Customize Modules card. Presented by `ContentView` (hoisted above
    /// the viewer like every other editor modal) and mirrored into
    /// `AppState.modalPresented` so Escape and the key catcher see it.
    @Published var customizeShown = false

    var reorderMode: Bool { reorderDraft != nil }

    /// What the panels should DRAW — the draft while rearranging, so the bars
    /// move as you drag without any of it being committed.
    var active: EditorWorkspace { reorderDraft ?? workspace }

    private init() {
        workspace = AppSettings.editorWorkspace
    }

    // MARK: - Committed edits

    /// View ▸ Editor Workspace ▸ Default Layout. The one action that clears the
    /// hidden set as well as the order — the floating bar's Reset deliberately
    /// does not (see `resetDraft`).
    func resetToDefault() {
        cancelReorder()
        commit(.standard)
    }

    /// Customize applies live, so this persists immediately.
    func setHidden(_ module: EditorModule, _ shouldHide: Bool) {
        var next = workspace
        next.setHidden(module, shouldHide)
        commit(next)
    }

    // MARK: - Reorder transaction

    func beginReorder() {
        guard reorderDraft == nil else { return }
        customizeShown = false
        reorderDraft = workspace
    }

    func updateDraft(_ next: EditorWorkspace) {
        guard reorderDraft != nil else { return }
        reorderDraft = next
    }

    /// The floating bar's Reset: standard order and sides, hidden set UNTOUCHED.
    /// Visibility belongs to Customize, and a Reset that silently un-hid four
    /// cards would be reaching across that line. Stays in the mode, so Cancel
    /// can still undo the reset.
    func resetDraft() {
        guard let draft = reorderDraft else { return }
        reorderDraft = EditorWorkspace(left: EditorWorkspace.standard.left,
                                       right: EditorWorkspace.standard.right,
                                       hidden: draft.hidden)
    }

    func saveReorder() {
        guard let draft = reorderDraft else { return }
        reorderDraft = nil
        commit(draft)
    }

    func cancelReorder() {
        reorderDraft = nil
    }

    /// The editor left the screen. Anything in flight is discarded — leaving
    /// the mode by any route other than Save is a cancel.
    func editorDismissed() {
        cancelReorder()
        customizeShown = false
    }

    // MARK: -

    private func commit(_ next: EditorWorkspace) {
        workspace = next
        AppSettings.editorWorkspace = next
    }

    #if DEBUG
    /// Re-read the preference. Tests only — the store is a singleton and each
    /// test needs it to start from the defaults it just wrote.
    func reloadForTesting() {
        reorderDraft = nil
        customizeShown = false
        workspace = AppSettings.editorWorkspace
    }
    #endif
}
