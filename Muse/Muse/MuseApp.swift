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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    // fluidSim starts on demand via AppState.fluidEnabled —
                    // a 60fps CPU timer must not run while the effect is off.
                    ThumbnailCache.shared.enforceDiskCap()
                    // 180-day retention for data of removed folders.
                    if let queue = Database.shared.dbQueue {
                        let roots = appState.bookmarks.roots
                            .compactMap { $0.resolveURL()?.standardizedFileURL.path }
                        await Housekeeping.pruneUnreachable(queue: queue,
                                                            rootPaths: roots)
                    }
                }
        }
        .commands {
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
