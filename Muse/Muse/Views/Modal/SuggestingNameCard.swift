//
//  SuggestingNameCard.swift
//  Muse
//
//  "Type a name, or pick one you already use." The shared card behind the
//  grid's Add Tag and New Collection prompts.
//
//  These were SwiftUI `.alert`s, which can host only TextFields and Buttons —
//  a suggestion list is structurally impossible inside one, so a user had no way
//  to see that "sunset" already existed before typing "Sunsets". As in-window
//  cards they can show the list.
//
//  Modal rules this obeys (see Views/Modal/ModalPresenter.swift):
//   - presented at the SHELL, never from a tile or a row;
//   - naturally sized, NO inner ScrollView — the list is capped and spills into
//     a "+N more" line rather than scrolling, so the presenter's own measurement
//     stays valid;
//   - the draft lives in LOCAL @State and reaches AppState only on commit.
//     Binding a TextField straight to a @Published on AppState re-evaluates the
//     whole shell on every keystroke.
//

import SwiftUI

struct SuggestingNameCard: View {
    let title: String
    /// One line under the title saying what this will act on.
    let subtitle: String
    let placeholder: String
    /// Everything that already exists, for the suggestion list.
    let candidates: [TagSuggest.Candidate]
    /// Canonical label → the term to SHOW. Suggestions are matched on the shown
    /// term (a French user types "chien") but commit the canonical one.
    var displaying: (String) -> String = { $0 }
    let confirmTitle: String
    /// Called with the canonical label — a suggestion's own label, or the raw
    /// text when the user is creating something new.
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    /// Index into `shown` of the keyboard-highlighted row, or nil when the
    /// user hasn't arrowed into the list (Return then creates the typed text).
    @State private var highlighted: Int?
    @FocusState private var fieldFocused: Bool

    /// Rows shown at once. The card is naturally sized, so an uncapped list
    /// would grow past the window and defeat the presenter's height cap.
    private static let maxRows = 8

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ranked matches, plus how many were dropped by the cap.
    private var ranked: [TagSuggest.Candidate] {
        TagSuggest.rank(candidates, query: draft, displaying: displaying,
                        limit: Self.maxRows + 1)
    }
    private var shown: ArraySlice<TagSuggest.Candidate> { ranked.prefix(Self.maxRows) }
    private var overflow: Int { max(0, ranked.count - Self.maxRows) }

    /// An exact hit on something that already exists — the create button then
    /// reads as picking it rather than making a duplicate.
    private var exactMatch: TagSuggest.Candidate? {
        candidates.first { displaying($0.label).compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                SheetCloseButton { onCancel() }
            }
            .padding(.bottom, 16)

            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(commit)
                // Typing invalidates any arrowed-to row: the list under the
                // cursor has just changed, so a stale index would commit
                // whatever happens to sit at that position now.
                .onChange(of: draft) { _, _ in highlighted = nil }

            if !shown.isEmpty {
                suggestionList
                    .padding(.top, 12)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty && highlighted == nil)
            }
            .padding(.top, 20)
        }
        .padding(24)
        // Arrow keys drive the list even while the field holds focus — a text
        // field ignores ↑/↓ for a single-line value, so they're free to mean
        // "move through the suggestions" here.
        .onKeyPress(.upArrow) { moveHighlight(-1) }
        .onKeyPress(.downArrow) { moveHighlight(1) }
        .onAppear { fieldFocused = true }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.isEmpty ? String(localized: "Already in use")
                               : String(localized: "Matches"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            // A plain VStack, NOT a List or a ScrollView: this card is measured
            // by the presenter and a scroller would take every point offered.
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, candidate in
                suggestionRow(candidate, index: index)
            }

            if overflow > 0 {
                Text("+\(overflow) more — keep typing to narrow")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private func suggestionRow(_ candidate: TagSuggest.Candidate, index: Int) -> some View {
        let isHighlighted = highlighted == index
        return Button {
            onCommit(candidate.label)
        } label: {
            HStack(spacing: 8) {
                Text(displaying(candidate.label))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if candidate.count > 0 {
                    Text("\(candidate.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHighlighted ? Color.accentColor.opacity(0.18) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    /// Return commits the arrowed-to suggestion if there is one; otherwise the
    /// typed text — so creating something new never needs the mouse, and
    /// picking an existing one never needs to retype it exactly.
    private func commit() {
        if let i = highlighted, shown.indices.contains(shown.startIndex + i) {
            onCommit(Array(shown)[i].label)
            return
        }
        // An exact typed match commits the EXISTING label rather than the raw
        // text, so differing case or accents can't mint a near-duplicate.
        if let match = exactMatch {
            onCommit(match.label)
            return
        }
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }

    /// Move the highlight, clamped at both ends. Arrowing UP off the first row
    /// returns to "nothing highlighted", which is how you get back to creating
    /// the text you typed.
    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        guard !shown.isEmpty else { return .ignored }
        switch (highlighted, delta) {
        case (nil, 1):          highlighted = 0
        case (nil, _):          return .ignored
        case (let i?, _):
            let next = i + delta
            highlighted = next < 0 ? nil : min(next, shown.count - 1)
        }
        return .handled
    }
}
