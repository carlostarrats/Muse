//
//  SearchBar.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI
import Combine

/// A search bar that debounces input by 300 ms before triggering a tag-aware
/// database search via AppState. Cancels any in-flight search Task when a new
/// query arrives.
struct SearchBar: View {

    @EnvironmentObject var appState: AppState

    // Local text state drives the Combine pipeline; appState.searchQuery is
    // updated only after the debounce fires.
    @State private var text: String = ""
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    // Publisher that fires whenever `text` changes.
    private let textSubject = PassthroughSubject<String, Never>()
    // Holds the Combine subscription for the lifetime of this view.
    @State private var cancellable: AnyCancellable?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search images, notes, tags…", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onChange(of: text) { _, newValue in
                    textSubject.send(newValue)
                }

            if !text.isEmpty {
                Button {
                    clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onAppear {
            // Wire up the 300 ms debounce once when the view first appears.
            cancellable = textSubject
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak appState] debouncedQuery in
                    guard let appState else { return }
                    // Cancel any previous in-flight search before starting a new one.
                    searchTask?.cancel()
                    searchTask = Task {
                        await appState.searchImages(query: debouncedQuery)
                    }
                }
        }
        .onReceive(NotificationCenter.default.publisher(for: .museSearchBarFocus)) { _ in
            isFocused = true
        }
    }

    // MARK: - Private

    private func clearSearch() {
        text = ""
        searchTask?.cancel()
        searchTask = Task {
            await appState.searchImages(query: "")
        }
    }
}

#Preview {
    SearchBar()
        .environmentObject(AppState())
        .padding()
        .frame(width: 360)
}
