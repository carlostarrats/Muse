//
//  SuggestingNameCard.swift
//  Muse
//
//  "Type a name, or pick one you already use." The shared card behind the
//  grid's Add Tag and New Collection prompts.
//
//  These were SwiftUI `.alert`s, which can host only TextFields and Buttons —
//  so a user had no way to see that "sunset" already existed before typing
//  "Sunsets". As an in-window card it can show the matches.
//
//  The result list is a FIXED number of rows, reserved whether or not they're
//  filled. That's the whole reason the count is capped: a list that grew and
//  shrank with the query resized the card on every keystroke, moving the
//  buttons out from under the cursor.
//
//  Modal rules this obeys (see Views/Modal/ModalPresenter.swift):
//   - presented at the SHELL, never from a tile or a row;
//   - naturally sized and CONSTANT — see the reserved rows above;
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
    /// Everything that already exists, filtered as the user types.
    let candidates: [TagSuggest.Candidate]
    /// What to show BEFORE anything is typed. For Add Tag these are tags carried
    /// by visually similar photos; empty falls back to the most-used candidates.
    var suggestions: [TagSuggest.Candidate] = []
    /// Canonical label → the term to SHOW. Matching runs on the shown term (a
    /// French user types "chien") but commits the canonical one.
    var displaying: (String) -> String = { $0 }
    let confirmTitle: String
    /// Called with the canonical label — a row's own label, or the typed text
    /// when the user is creating something new.
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    /// Index of the keyboard-highlighted row, or nil when the user hasn't
    /// arrowed into the list (Return then commits the typed text).
    @State private var highlighted: Int?
    @FocusState private var fieldFocused: Bool

    /// Rows the list holds — and always reserves. Small on purpose: this is a
    /// suggestion, not a browser. Typing narrows toward what you want; the tag
    /// you can't find this way is one you're about to create anyway.
    static let rowCount = 5
    private static let rowHeight: CGFloat = 26

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Empty field → the caller's suggestions (falling back to most-used);
    /// typing → matches from the full pool.
    private var shown: [TagSuggest.Candidate] {
        if trimmed.isEmpty {
            let base = suggestions.isEmpty
                ? TagSuggest.rank(candidates, query: "", displaying: displaying,
                                  limit: Self.rowCount)
                : suggestions
            return Array(base.prefix(Self.rowCount))
        }
        return TagSuggest.rank(candidates, query: draft, displaying: displaying,
                               limit: Self.rowCount)
    }

    /// An exact hit on something that already exists — committing then reuses
    /// it rather than minting a near-duplicate that differs only in case.
    private var exactMatch: TagSuggest.Candidate? {
        candidates.first {
            displaying($0.label).compare(trimmed,
                                         options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }
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
                        .lineLimit(1)
                        .truncationMode(.middle)
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
                // cursor just changed, so a stale index would commit whatever
                // happens to sit at that position now.
                .onChange(of: draft) { _, _ in highlighted = nil }

            suggestionList
                .padding(.top, 12)

            HStack {
                Spacer()
                ModalButton(title: String(localized: "Cancel"), isCancel: true) { onCancel() }
                ModalButton(title: confirmTitle, kind: .prominent, isDefault: true) { commit() }
                    .disabled(trimmed.isEmpty && highlighted == nil)
            }
            .padding(.top, 20)
        }
        .padding(24)
        // Arrow keys drive the list even while the field holds focus: a
        // single-line field ignores ↑/↓, so they're free to mean "move through
        // the suggestions" here.
        .onKeyPress(.upArrow) { moveHighlight(-1) }
        .onKeyPress(.downArrow) { moveHighlight(1) }
        .onAppear { fieldFocused = true }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Always "Suggestions" — the heading names what the area IS, and
            // swapping it to "Matches" mid-type made it read as a different
            // control appearing under the cursor.
            Text("Suggestions")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            // A plain VStack, NOT a List or a ScrollView: this card is measured
            // by the presenter and a scroller would take every point offered.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, candidate in
                    row(candidate, index: index)
                }
            }
            // Reserve every row's height whether or not it's filled, so the
            // card is exactly as tall with five matches as with none.
            .frame(height: Self.rowHeight * CGFloat(Self.rowCount), alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ candidate: TagSuggest.Candidate, index: Int) -> some View {
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
            .frame(height: Self.rowHeight)
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

    /// Return commits the arrowed-to row if there is one; otherwise the typed
    /// text — so creating something new never needs the mouse, and picking an
    /// existing one never needs to retype it exactly.
    private func commit() {
        if let i = highlighted, shown.indices.contains(i) {
            onCommit(shown[i].label)
            return
        }
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
        let rows = shown
        guard !rows.isEmpty else { return .ignored }
        switch (highlighted, delta) {
        case (nil, 1):  highlighted = 0
        case (nil, _):  return .ignored
        case (let i?, _):
            let next = i + delta
            highlighted = next < 0 ? nil : min(next, rows.count - 1)
        }
        return .handled
    }
}
