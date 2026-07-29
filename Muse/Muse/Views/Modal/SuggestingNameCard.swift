//
//  SuggestingNameCard.swift
//  Muse
//
//  "Type a name — we'll complete it if it already exists." The shared card
//  behind the grid's Add Tag and New Collection prompts.
//
//  These were SwiftUI `.alert`s, which can host only TextFields and Buttons, so
//  a user had no way to see that "sunset" already existed before typing
//  "Sunsets". The first pass at fixing that dropped a full filtered LIST under
//  the field — but a list is a lot of card for a job the field can do itself,
//  and its changing length made the card resize on every keystroke.
//
//  So: the field INLINE-COMPLETES against what exists (type "sun", see
//  "sun|set" with "set" selected — Return or → accepts, Delete rejects), and
//  below it sits a short, FIXED row of suggested tags. Nothing about the card's
//  size depends on what you've typed.
//
//  Modal rules this obeys (see Views/Modal/ModalPresenter.swift):
//   - presented at the SHELL, never from a tile or a row;
//   - naturally sized and CONSTANT — the suggestion area reserves its height
//     whether or not it has content, so the card never grows or shrinks while
//     the user types;
//   - the draft lives in LOCAL @State and reaches AppState only on commit.
//     Binding a TextField straight to a @Published on AppState re-evaluates the
//     whole shell on every keystroke.
//

import SwiftUI
import AppKit

struct SuggestingNameCard: View {
    let title: String
    /// One line under the title saying what this will act on.
    let subtitle: String
    let placeholder: String
    /// Everything that already exists — the pool the field completes against.
    let candidates: [TagSuggest.Candidate]
    /// A short, pre-ranked row of offers shown under the field. For Add Tag
    /// these are tags carried by visually similar photos; empty is fine.
    var suggestions: [TagSuggest.Candidate] = []
    /// Heading above the suggestion row.
    var suggestionsTitle: String = ""
    /// Canonical label → the term to SHOW. Completion matches on the shown term
    /// (a French user types "chien") but commits the canonical one.
    var displaying: (String) -> String = { $0 }
    let confirmTitle: String
    /// Called with the canonical label — a suggestion's own label, or the typed
    /// text when the user is creating something new.
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    /// How many offers the row holds. Fixed: the row reserves this much height
    /// even when it has fewer, so the card can't resize as suggestions load.
    static let suggestionSlots = 6

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The pool the field completes against, as display terms.
    private var completionPool: [String] {
        candidates.map { displaying($0.label) }
    }

    /// Canonical label for a display term the user has landed on, so committing
    /// an inline completion writes the stored key, not the translated text.
    private func canonical(for displayed: String) -> String {
        candidates.first {
            displaying($0.label).compare(displayed, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }?.label ?? displayed
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

            CompletingTextField(text: $draft,
                                placeholder: placeholder,
                                completions: completionPool,
                                onSubmit: commit)
                .frame(height: 22)
                .focused($fieldFocused)

            suggestionRow
                .padding(.top, 16)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .onAppear { fieldFocused = true }
    }

    /// Fixed-height offers area. It reserves its space unconditionally — the
    /// suggestions arrive from an async lookup, and a row that appears late
    /// would otherwise shove the buttons down under the user's cursor.
    private var suggestionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(suggestionsTitle)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(suggestions.isEmpty ? 0 : 1)

            PillFlow(gap: 6, hovered: nil) {
                ForEach(suggestions.prefix(Self.suggestionSlots)) { candidate in
                    Button {
                        onCommit(candidate.label)
                    } label: {
                        Text(displaying(candidate.label))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                            .background(Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.08)))
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // Two rows of 22pt pills + gap + heading: the most the flow can use at
        // `suggestionSlots`. Held constant so the card's height is fixed.
        .frame(height: 62, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Commit the typed text (inline completion included — the field's text
    /// already contains the completed suffix), mapped back to its canonical
    /// label so differing case or accents can't mint a near-duplicate.
    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit(canonical(for: trimmed))
    }
}

// MARK: - Inline-completing field

/// An `NSTextField` that completes as you type: the matched suffix is inserted
/// and left SELECTED, so continuing to type replaces it and Delete rejects it.
///
/// AppKit, not SwiftUI: `TextField` has no way to place a selection range, which
/// is the entire mechanism here. `NSTextView.complete(_:)` isn't used either —
/// it opens the system completion DROPDOWN, which is the list this design
/// deliberately removed.
private struct CompletingTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let completions: [String]
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.sendsActionOnEndEditing = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Only write when the value genuinely differs: assigning stringValue
        // resets the insertion point, which would fight the completion's
        // selection on every re-render.
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CompletingTextField
        /// True while we're programmatically inserting a completion, so the
        /// resulting change notification doesn't recurse into completing again.
        private var isCompleting = false

        init(_ parent: CompletingTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            guard !isCompleting else { return }

            let typed = field.stringValue
            parent.text = typed

            // Only complete when the caret is at the END of what was typed —
            // completing mid-edit (after a Delete, or an insertion in the
            // middle) would fight the user rather than help.
            guard !typed.isEmpty,
                  let editor = field.currentEditor(),
                  editor.selectedRange.location == typed.count,
                  editor.selectedRange.length == 0,
                  let match = bestCompletion(for: typed)
            else { return }

            isCompleting = true
            field.stringValue = match
            // Leave the ADDED suffix selected: typing on replaces it, Delete
            // removes it, → accepts it. That's the standard inline-completion
            // contract (Safari's address bar, Mail's To: field).
            editor.selectedRange = NSRange(location: typed.count,
                                           length: match.count - typed.count)
            parent.text = match
            isCompleting = false
        }

        /// Shortest prefix match, so the completion is the least presumptuous
        /// one available; alphabetical breaks ties so it doesn't flicker
        /// between equals as the pool re-orders.
        private func bestCompletion(for typed: String) -> String? {
            let needle = fold(typed)
            guard !needle.isEmpty else { return nil }
            return parent.completions
                .filter { fold($0).hasPrefix(needle) && $0.count > typed.count }
                .min { a, b in
                    a.count != b.count ? a.count < b.count
                        : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
                }
        }

        private func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            // → at the end of the text accepts the completion by collapsing the
            // selection, rather than moving the caret out of a selected suffix.
            if selector == #selector(NSResponder.moveRight(_:)),
               textView.selectedRange.length > 0 {
                textView.selectedRange = NSRange(
                    location: textView.string.count, length: 0)
                return true
            }
            return false
        }
    }
}
