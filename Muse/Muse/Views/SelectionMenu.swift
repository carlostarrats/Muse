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
        // Remove from the tag/collection you're currently viewing. Shown only
        // in that context (a tag filter or an open collection); acts on the
        // effective selection.
        if appState.activeTagLabel != nil || appState.activeCollectionID != nil {
            Divider()
            if let label = appState.activeTagLabel {
                Button("Remove Tag “\(label)”") {
                    appState.removeTag(label, fromURLs: urls)
                }
            }
            if let cid = appState.activeCollectionID {
                Button("Remove from Collection “\(collectionName(cid))”") {
                    appState.removeFromCollection(cid, urls: urls)
                }
            }
            Divider()
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

    /// Display name of the active collection, for the remove menu label.
    private func collectionName(_ id: String) -> String {
        engine.collections.first { $0.collection.id == id }?.collection.name ?? "Collection"
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
