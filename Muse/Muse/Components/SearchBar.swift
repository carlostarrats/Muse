//
//  SearchBar.swift
//  Muse
//
//  FTS5-backed search bar with current-folder vs everywhere scope
//  toggle. 250ms debounce so we don't fire a query on every keystroke.
//

import SwiftUI
import Combine

struct SearchBar: View {
    @EnvironmentObject var appState: AppState

    @State private var text: String = ""
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search files, tags, captions…", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onChange(of: text) { _, newValue in
                    guard newValue != appState.searchQuery else { return }
                    appState.searchQuery = newValue
                    debounceAndRun(query: newValue)
                }
                // programmatic searches (e.g. viewer tag taps) show in the bar
                .onChange(of: appState.searchQuery) { _, newValue in
                    if text != newValue { text = newValue }
                }
                .onSubmit {
                    fire(query: text)
                }

            Toggle(isOn: $appState.searchEverywhere) {
                Image(systemName: appState.searchEverywhere
                      ? "globe"
                      : "folder")
            }
            .toggleStyle(.button)
            .controlSize(.mini)
            .help(appState.searchEverywhere
                  ? "Searching the entire indexed library"
                  : "Searching the current folder")
            .onChange(of: appState.searchEverywhere) { _, _ in
                fire(query: text)
            }

            if !text.isEmpty {
                Button {
                    text = ""
                    appState.searchQuery = ""
                    appState.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .frame(minWidth: 240, maxWidth: 420)
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
