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
            onChange: handleChange,
            onSubmit: { fire(query: $0) }
        )
        .frame(minWidth: 320, maxWidth: 640)
        // Programmatic searches (e.g. viewer tag taps) push their query into the
        // field for display; the search itself was already run by the caller.
        .onChange(of: appState.searchQuery) { _, newValue in
            if text != newValue { text = newValue }
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

/// The native AppKit search field wrapped for SwiftUI. Brings the system focus
/// ring, the native clear button, and accessibility; its appearance is forced
/// to the app's current mood (light/dark) so it matches the surrounding colors.
private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var scheme: ColorScheme
    var onChange: (String) -> Void
    var onSubmit: (String) -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search files, tags, captions…"
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.focusRingType = .default
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        init(_ parent: NativeSearchField) { self.parent = parent }

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
