//
//  SearchBar.swift
//  Muse
//
//  Native macOS search field (NSSearchField), scoped to the folder selected in
//  the sidebar. 250ms debounce so we don't fire a query on every keystroke.
//  Using the real control gives the system focus ring, the native clear button,
//  and full accessibility for free; its appearance follows the current mood so
//  the colors match the app.
//

import SwiftUI
import AppKit

struct SearchBar: View {
    @EnvironmentObject var appState: AppState

    @State private var text: String = ""
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        NativeSearchField(
            text: $text,
            scheme: appState.moodPalette.scheme,
            allFolders: appState.searchAllFolders,
            onChange: handleChange,
            onSubmit: { fire(query: $0) },
            onScopeChange: handleScopeChange
        )
        .frame(minWidth: 280, maxWidth: 640)
        // Programmatic searches (e.g. viewer tag taps) push their query into the
        // field for display; the search itself was already run by the caller.
        .onChange(of: appState.searchQuery) { _, newValue in
            if text != newValue { text = newValue }
            // An external clear (e.g. selecting a folder) must also kill any
            // in-flight debounce, or a search the user just dismissed would
            // fire ~250ms later and re-activate with a now-cleared query.
            if newValue.isEmpty { debounceTask?.cancel() }
        }
    }

    private func handleChange(_ newValue: String) {
        guard newValue != appState.searchQuery else { return }
        appState.searchQuery = newValue
        if newValue.isEmpty {
            appState.clearSearch()
        } else {
            debounceAndRun(query: newValue)
        }
    }

    /// Magnifier menu picked a new scope (All vs This folder). Re-run an active
    /// search immediately under the new scope; an idle search just stores it.
    private func handleScopeChange(_ allFolders: Bool) {
        guard appState.searchAllFolders != allFolders else { return }
        appState.searchAllFolders = allFolders
        let q = appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if appState.isSearchActive, !q.isEmpty { fire(query: q) }
    }

    // MARK: - Debounce

    private func debounceAndRun(query: String) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled {
                fire(query: query)
            }
        }
    }

    private func fire(query: String) {
        Task { await appState.runSearch(query) }
    }
}

/// NSSearchField with the editable text started a few px right of the system
/// default. (The magnifier + menu chevron are one system-drawn glyph, so the
/// gap between them can't be nudged from here.)
private final class InsetSearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { InsetSearchFieldCell.self }
        set { }
    }
}

private final class InsetSearchFieldCell: NSSearchFieldCell {
    /// Start the search text ~4px right of the system default.
    private let textRightShift: CGFloat = 4

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var r = super.searchTextRect(forBounds: rect)
        r.origin.x += textRightShift
        r.size.width -= textRightShift
        return r
    }
}

/// The native AppKit search field wrapped for SwiftUI. Brings the system focus
/// ring, the native clear button, and accessibility; its appearance is forced
/// to the app's current mood (light/dark) so it matches the surrounding colors.
private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var scheme: ColorScheme
    /// Current scope: true = whole library ("All"), false = the selected folder.
    var allFolders: Bool
    var onChange: (String) -> Void
    var onSubmit: (String) -> Void
    var onScopeChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = InsetSearchField()
        field.placeholderString = "Search files, tags, captions…"
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.focusRingType = .default
        // The magnifier-icon dropdown: "All" vs "This Folder". Setting a
        // template (with no Recents tags) shows the dropdown triangle and our
        // two scope items, no recent-searches machinery.
        field.searchMenuTemplate = context.coordinator.makeScopeMenu(allFolders: allFolders)
        context.coordinator.appliedAllFolders = allFolders
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        // Keep the menu's checkmark in sync with the current scope. The field
        // caches its own copy of the template and won't re-read mutated items,
        // so on a scope change we hand it a FRESH template (with the right
        // checkmarks) — reassigning forces the field to rebuild the menu.
        if context.coordinator.appliedAllFolders != allFolders {
            field.searchMenuTemplate = context.coordinator.makeScopeMenu(allFolders: allFolders)
            context.coordinator.appliedAllFolders = allFolders
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        /// The scope the currently-installed template reflects, so updateNSView
        /// only rebuilds (and reassigns) the menu when it actually changes.
        var appliedAllFolders: Bool?
        init(_ parent: NativeSearchField) { self.parent = parent }

        /// A fresh two-item scope menu with the checkmark on the active scope.
        func makeScopeMenu(allFolders: Bool) -> NSMenu {
            let menu = NSMenu()
            let all = NSMenuItem(title: "All", action: #selector(pickAll), keyEquivalent: "")
            all.target = self
            all.state = allFolders ? .on : .off
            let folder = NSMenuItem(title: "This Folder", action: #selector(pickFolder), keyEquivalent: "")
            folder.target = self
            folder.state = allFolders ? .off : .on
            menu.addItem(all)
            menu.addItem(folder)
            return menu
        }

        // The checkmark refresh rides the resulting scope change: onScopeChange
        // flips appState.searchAllFolders → updateNSView reinstalls a fresh
        // template with the correct checkmarks.
        @objc private func pickAll() { parent.onScopeChange(true) }
        @objc private func pickFolder() { parent.onScopeChange(false) }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
            parent.onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit(parent.text)
                return true
            }
            return false
        }
    }
}
