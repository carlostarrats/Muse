//
//  ModalPromptCard.swift
//  Muse
//
//  The shared "type a name" card — Rename Collection / Rename File / New
//  Subfolder / Rename Folder / Rename Tag. The in-window replacement for the
//  `.alert`-with-a-TextField those used to be (see ModalMessageCard for why
//  system alerts left).
//
//  Not SuggestingNameCard: that one exists to show you what already exists
//  before you mint a near-duplicate. These prompts rename ONE known thing, so
//  there's nothing to suggest — just a field.
//
//  Modal rules this obeys (see ModalPresenter):
//   - presented at the SHELL, never from the row that raised it;
//   - naturally sized, no inner ScrollView;
//   - the draft lives in LOCAL @State and reaches AppState only on commit.
//     Binding a TextField to a @Published on AppState re-evaluates the whole
//     shell on every keystroke (visible typing lag on slower Macs). The card is
//     built only while presented, so `.onAppear` seeding gives a fresh draft
//     every time it opens — no external seeding plumbing needed.
//

import SwiftUI

struct ModalPromptCard: View {
    let title: String
    /// One line under the field saying what committing will do.
    let message: String
    let placeholder: String
    let confirmTitle: String
    /// Seeds the field on open (the current name, or empty for a new thing).
    var initialText: String = ""
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                SheetCloseButton { onCancel() }
            }

            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                .padding(.top, 14)

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            HStack {
                Spacer()
                ModalButton(title: String(localized: "Cancel"), isCancel: true) { onCancel() }
                ModalButton(title: confirmTitle, kind: .prominent, isDefault: true) { commit() }
                    .disabled(trimmed.isEmpty)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .onAppear {
            draft = initialText
            focused = true
        }
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}
