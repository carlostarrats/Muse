//
//  MuseApp.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI

@main
struct MuseApp: App {
    @StateObject private var appState = AppState()
    /// Sparkle self-updater (direct-distribution build only). Started at
    /// launch so background checks honor the user's preference.
    @StateObject private var updater = UpdaterController()

    /// Pin / Unpin label reflects the selected folder's current state.
    private var pinMenuTitle: String {
        guard let folder = appState.selectedFolder else { return "Pin Folder" }
        return appState.stars.isStarred(folder.url) ? "Unpin Folder" : "Pin Folder"
    }

    /// The added root matching the current selection, if it is a root —
    /// only roots can be removed from the library.
    private var selectedRoot: Root? {
        guard let folder = appState.selectedFolder, folder.isRoot else { return nil }
        return appState.bookmarks.roots.first {
            appState.bookmarks.url(for: $0) == folder.url
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    ThumbnailCache.shared.enforceDiskCap()
                    // 180-day retention for data of removed folders.
                    if let queue = Database.shared.dbQueue {
                        let roots = appState.bookmarks.roots
                            .compactMap { $0.resolveURL()?.standardizedFileURL.path }
                        await Housekeeping.pruneUnreachable(queue: queue,
                                                            rootPaths: roots)
                    }
                    Task { await IntentBackfill.run() }
                }
        }
        .commands {
            // "Check for Updates…" sits in the Muse app menu, right below
            // "About Muse" — the conventional spot every Mac app uses.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater.controller.updater)
            }

            // Folder actions on the current selection live in the Edit menu.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button(pinMenuTitle) {
                    if let folder = appState.selectedFolder {
                        appState.toggleStar(folder: folder)
                    }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(appState.selectedFolder == nil)

                Button("Remove Folder") {
                    if let root = selectedRoot {
                        appState.removeRoot(root)
                    }
                }
                .disabled(selectedRoot == nil)

                Button("Set as Collection Cover") {
                    if let file = appState.selectedFile {
                        appState.setCollectionCover(file)
                    }
                }
                .disabled(appState.activeCollectionID == nil || appState.selectedFile == nil)
            }

            // Library tools live in the File menu.
            CommandGroup(after: .newItem) {
                Divider()
                Button("Find Duplicates in Folder") {
                    appState.findDuplicatesInCurrentFolder()
                }
            }

            // Menu-bar equivalents of the chip context menu — keyboard and
            // VoiceOver reachable. Enabled while a tag filter is selected.
            CommandMenu("Tags") {
                Button("Rename Tag…") {
                    if let label = appState.activeTagLabel {
                        appState.tagRenameRequest = label
                    }
                }
                .disabled(appState.activeTagLabel == nil)

                Button("Delete Tag…") {
                    if let label = appState.activeTagLabel {
                        appState.tagDeleteRequest = label
                    }
                }
                .disabled(appState.activeTagLabel == nil)

                Divider()

                Button("Clear Tag Filter") {
                    appState.setActiveTag(nil)
                }
                .disabled(appState.activeTagLabel == nil)

                Divider()

                Button("Delete All Tags…") {
                    appState.deleteAllTagsRequest = true
                }
                .disabled(!appState.bulkTagCommandsAvailable)

                Button("Regenerate Tags…") {
                    appState.regenerateTagsRequest = true
                }
                .disabled(!appState.bulkTagCommandsAvailable)
            }

            // Same for collections — enabled while inside one.
            CommandMenu("Collections") {
                Button("Rename Collection…") {
                    appState.collectionRenameRequest = true
                }
                .disabled(appState.activeCollectionID == nil)

                Button("Delete Collection…") {
                    appState.collectionDeleteRequest = true
                }
                .disabled(appState.activeCollectionID == nil)

                Divider()

                Button("Back to Library") {
                    appState.setActiveCollection(nil)
                }
                .disabled(appState.activeCollectionID == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
