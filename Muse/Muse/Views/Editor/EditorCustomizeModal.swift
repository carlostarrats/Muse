//
//  EditorCustomizeModal.swift
//  Muse
//
//  View ▸ Editor Workspace ▸ Customize Modules…
//
//  Which of the twelve control cards the editor shows. It applies LIVE — no OK
//  button — so you can watch a card leave the panel behind the modal. A confirm
//  step on a checkbox list is ceremony, and each write persists on its own (see
//  EditorWorkspaceStore.setHidden).
//
//  It does NOT reorder. No handles, no up/down arrows: reorder is its own mode
//  with its own gestures, and two ways to do one thing in two places drift
//  apart.
//
//  Rows are listed in PANEL order — left column top to bottom, then right — so
//  the list reads like the thing it edits.
//
//  All twelve are always listed, including INSIGHTS, which only DRAWS when the
//  photo has feedback notes, Lightroom provenance or a pinned RAW decoder. A
//  list that changed length depending on which photo you happened to be looking
//  at would be worse than a stable one, and the checkbox reads the same either
//  way: show this card when it has something to say.
//

import SwiftUI

struct EditorCustomizeModal: View {
    @Binding var isPresented: Bool
    @ObservedObject private var store = EditorWorkspaceStore.shared

    /// Panel order, so the list reads top-to-bottom the way the editor does.
    private var rows: [EditorModule] { store.workspace.left + store.workspace.right }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Customize Modules")
                    .font(.system(size: 24, weight: .semibold))
                Spacer()
                SheetCloseButton { isPresented = false }
            }
            Text("Choose which control cards the editor shows. Hidden cards keep their place and come back where they were.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .padding(.bottom, 20)

            ModalScroll {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { module in
                        row(module)
                    }
                }
            }
        }
    }

    private func row(_ module: EditorModule) -> some View {
        let isVisible = !store.workspace.hidden.contains(module)
        // The LAST visible module cannot be hidden — an editor with no
        // controls, recoverable only through the menu bar, is a trap, and
        // "show me only the photo" is already the hide-UI eye's job, done
        // reversibly. The model enforces it too (EditorWorkspace.setHidden);
        // this is what makes the refusal visible rather than mysterious.
        let isLast = isVisible && store.workspace.visibleCount == 1
        return Toggle(isOn: Binding(get: { isVisible },
                                    set: { store.setHidden(module, !$0) })) {
            Text(module.title)
                .font(.system(size: 13))
        }
        .toggleStyle(.checkbox)
        .disabled(isLast)
        .padding(.vertical, 3)
        .help(isLast
              ? Text("At least one card has to stay visible")
              : Text("Show or hide this card in the editor"))
        .accessibilityLabel(Text(module.title))
        .accessibilityHint(isLast
                           ? Text("At least one card has to stay visible")
                           : Text("Show or hide this card in the editor"))
    }
}

extension View {
    /// Presents the Customize card and keeps `AppState.modalPresented` in step.
    ///
    /// Bundled into a modifier rather than two more links in `ContentView`'s
    /// modal chain: that chain is long enough that adding to it inline pushed
    /// the type-checker past its time limit.
    ///
    /// `onPresentationChange` writes the shell's mirror flag — the one that
    /// gates the grid's key catcher and Escape's modal peel. It is a callback
    /// rather than a binding because the mirror is deliberately not
    /// `@Published` on `AppState`; see the property there.
    func editorCustomizeModal(store: EditorWorkspaceStore,
                              palette: MoodPalette,
                              onPresentationChange: @escaping (Bool) -> Void) -> some View {
        museModal(isPresented: Binding(get: { store.customizeShown },
                                       set: { store.customizeShown = $0 }),
                  width: 420, palette: palette) {
            EditorCustomizeModal(isPresented: Binding(get: { store.customizeShown },
                                                      set: { store.customizeShown = $0 }))
        }
        .onChange(of: store.customizeShown) { _, shown in onPresentationChange(shown) }
    }
}
