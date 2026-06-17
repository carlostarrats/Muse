//
//  SelectionMenu.swift
//  Muse
//
//  The selection-aware actions shared by the grid tile's context menu:
//  add to an existing collection, add an existing tag, and share. Operates on
//  the effective selection (the selection, or just the right-clicked file).
//

import SwiftUI
import AppKit

struct SelectionActionsMenu: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var engine = CollectionsEngine.shared
    /// Standardized path of the right-clicked tile.
    let path: String

    private var urls: [URL] { appState.effectiveSelectionURLs(fallback: path) }

    var body: some View {
        Menu("Add to Collection") {
            if engine.collections.isEmpty {
                Button("No collections") {}.disabled(true)
            } else {
                ForEach(engine.collections.sorted {
                    $0.collection.name.localizedCaseInsensitiveCompare($1.collection.name) == .orderedAscending
                }, id: \.collection.id) { loaded in
                    Button(loaded.collection.name) { addToCollection(loaded.collection.id) }
                }
            }
        }
        Menu("Add Tag") {
            if appState.allTagLabels.isEmpty {
                Button("No tags") {}.disabled(true)
            } else {
                ForEach(appState.allTagLabels, id: \.self) { label in
                    Button(label) { addTag(label) }
                }
            }
        }
        Button("Share") { share() }
        Menu("Move to Folder") {
            let folders = moveDestinations
            if folders.isEmpty {
                Button("No folders") {}.disabled(true)
            } else {
                ForEach(folders, id: \.url) { dest in
                    Button(dest.name) { move(to: dest.url) }
                }
            }
        }
    }

    /// Top-level folders the selection can be moved into — the keyboard/
    /// VoiceOver alternative to dragging onto the sidebar.
    private var moveDestinations: [(name: String, url: URL)] {
        appState.bookmarks.roots.compactMap { root in
            guard let url = appState.bookmarks.url(for: root) else { return nil }
            return (url.lastPathComponent, url)
        }
    }

    private func move(to dest: URL) {
        let moving = urls
        appState.reloadAfterMove(failed: FileMover.move(moving, into: dest))
    }

    private func addToCollection(_ collectionID: String) {
        let paths = urls.map { $0.standardizedFileURL.path }
        Task { @MainActor in
            guard let q = Database.shared.dbQueue else { return }
            let ids = (try? await CollectionStore.fileIDs(queue: q, paths: paths)) ?? []
            for id in ids {
                try? await CollectionStore.addFile(queue: q, fileID: id, collectionID: collectionID)
            }
            await CollectionsEngine.shared.reload()
        }
    }

    private func addTag(_ label: String) {
        let targets = urls
        Task { @MainActor in
            for url in targets { _ = await TagStore.shared.addManualTag(label: label, for: url) }
            appState.tagsVersion &+= 1
        }
    }

    private func share() {
        guard let contentView = NSApp.keyWindow?.contentView, !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }
}
