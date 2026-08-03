//
//  EditorChromeCommand.swift
//  Muse
//
//  The seam between the View menu and the editor's hide-UI eye.
//
//  The menu bar is built in `MuseApp` and the editor is several layers inside
//  `ContentView`'s viewer overlay, so the command needs somewhere to meet. This
//  is a Pattern B singleton rather than two more `@Published`s on `AppState`:
//  the state is read by exactly one menu item and one view, and a property on
//  the monolith re-evaluates the whole `ContentView` body — sidebar and grid
//  included — every time the eye is toggled.
//
//  The editor owns the truth. This holds a MIRROR of `EditSession.uiHidden`, so
//  the menu can title itself and disable when there is no editor on screen, and
//  a request counter the editor turns into its own animated toggle (the panels
//  slide and the canvas insets are stepped frame by frame — see
//  `EditorView.toggleChrome`).
//

import SwiftUI

@MainActor
final class EditorChromeCommand: ObservableObject {
    static let shared = EditorChromeCommand()

    /// Mirrors `EditSession.uiHidden` while Edit is on screen; nil otherwise —
    /// which is what disables the menu item outside Edit mode.
    @Published private(set) var uiHidden: Bool?

    /// Bumped by the menu item. Only the count matters: the editor watches it
    /// and runs the toggle it would have run for a click on the eye.
    @Published private(set) var toggleRequests = 0

    private init() {}

    func editorPresented(uiHidden: Bool) { self.uiHidden = uiHidden }

    func editorDismissed() { uiHidden = nil }

    func requestToggle() { toggleRequests += 1 }
}
