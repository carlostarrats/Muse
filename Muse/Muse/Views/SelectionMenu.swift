//
//  SelectionMenu.swift
//  Muse
//
//  The selection-aware actions shared by the grid tile's context menu:
//  add to a new or existing collection, add a tag, remove from the active
//  tag/collection, share, and move to a folder. Operates on the effective
//  selection (the selection, or just the right-clicked file).
//

import SwiftUI
import AppKit

struct SelectionActionsMenu: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var engine = CollectionsEngine.shared
    /// Standardized path of the right-clicked tile.
    let path: String

    private var urls: [URL] { appState.effectiveSelectionURLs(fallback: path) }
    /// File-only subset (folders can't be tagged / collected / shared as files).
    private var fileURLs: [URL] {
        urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
        }
    }

    /// The rating shared by the effective selection (the checkmark target), or
    /// nil if mixed / unrated.
    private var currentRating: Int? {
        appState.uniformRating(forPaths: fileURLs.map { $0.standardizedFileURL.path })
    }

    /// Localized VoiceOver label for an N-star menu item (a bare glyph reads
    /// poorly). The number is interpolated.
    private func ratingA11yLabel(_ n: Int) -> String {
        String(format: NSLocalizedString("%lld-star rating",
                                         comment: "VoiceOver: star rating of a photo"),
               n)
    }

    var body: some View {
        if !fileURLs.isEmpty {
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
            Button("New Collection from Selection") { appState.requestNewCollection(fallback: path) }
            Menu("Add Tag") {
                if appState.allTagLabels.isEmpty {
                    Button("No tags") {}.disabled(true)
                } else {
                    ForEach(appState.allTagLabels, id: \.self) { label in
                        // Display the localized vision term (e.g. "chien"); the
                        // canonical English `label` is still what gets written.
                        Button(VocabularyLocalizer.shared.display(label)) { addTag(label) }
                    }
                }
            }
            Button("Share") { share() }
            Menu("Rating") {
                ForEach(Array((1...StarRating.maxStars).reversed()), id: \.self) { n in
                    let label = StarRating.label(for: n) ?? ""
                    Button {
                        // Pick the currently-checked rating to REMOVE it (no
                        // "Remove" verb); pick another to change.
                        appState.setRating(currentRating == n ? nil : n,
                                           forSelectionFallback: path)
                    } label: {
                        if currentRating == n {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                    .accessibilityLabel(Text(ratingA11yLabel(n)))
                }
            }
        }
        // Remove from the tag/collection you're currently viewing. Shown only
        // in that context (a tag filter or an open collection); acts on the
        // effective selection.
        if appState.singleActiveTag != nil || appState.activeCollectionID != nil {
            Divider()
            if let label = appState.singleActiveTag {
                Button("Remove Tag \u{201c}\(label)\u{201d}") {
                    appState.removeTag(label, fromURLs: urls)
                }
            }
            if let cid = appState.activeCollectionID {
                Button("Remove from Collection \u{201c}\(collectionName(cid))\u{201d}") {
                    appState.removeFromCollection(cid, urls: urls)
                }
            }
            Divider()
        }
        if !fileURLs.isEmpty {
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
        appState.moveFiles(fileURLs, into: dest)
    }

    private func addToCollection(_ collectionID: String) {
        let paths = fileURLs.map { $0.standardizedFileURL.path }
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
        let targets = fileURLs
        Task { @MainActor in
            for url in targets { _ = await TagStore.shared.addManualTag(label: label, for: url) }
            appState.tagsVersion &+= 1
        }
    }

    private func share() {
        guard let contentView = NSApp.keyWindow?.contentView, !fileURLs.isEmpty else { return }
        let picker = NSSharingServicePicker(items: fileURLs)
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }
}
