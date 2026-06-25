//
//  MuseApp.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI
import AppKit

@main
struct MuseApp: App {
    @StateObject private var appState = AppState()
    /// Sparkle self-updater (direct-distribution build only). Started at
    /// launch so background checks honor the user's preference.
    @StateObject private var updater = UpdaterController()
    /// Shared Google sign-in for the Drive share feature — one instance for the
    /// share UI, the Manage sheet, and the launch expiry sweep.
    @StateObject private var googleAuth = GoogleOAuth()

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

    /// The reorderable roots in displayed order — resolved bookmarks only, so it
    /// matches what the sidebar shows and the drag path uses (a root whose
    /// bookmark didn't resolve is hidden and must not shift the index).
    private var displayedReorderableRoots: [Root] {
        appState.rootNodes.compactMap { node in
            appState.bookmarks.roots.first {
                appState.bookmarks.url(for: $0) == node.url
            }
        }
    }

    /// The selected root's index in the manual reorder order (nil if not a
    /// reorderable root). Backs the Edit-menu Move Up/Down gating.
    private var selectedRootIndex: Int? {
        guard let r = selectedRoot else { return nil }
        return displayedReorderableRoots.firstIndex(of: r)
    }

    /// Reorder is only meaningful in Manual sort with more than one root.
    private var canReorderSelectedRoot: Bool {
        appState.folderSortMode == .manual
            && selectedRoot != nil
            && displayedReorderableRoots.count > 1
    }

    /// Move the selected root one slot earlier (-1) or later (+1) in the manual
    /// order — the keyboard/menu parallel to the sidebar's drag-to-reorder.
    private func moveSelectedRoot(by delta: Int) {
        let list = displayedReorderableRoots
        guard let r = selectedRoot, let i = list.firstIndex(of: r),
              list.indices.contains(i + delta) else { return }
        appState.bookmarks.reorder(r, relativeTo: list[i + delta],
                                   placeAfter: delta > 0)
    }

    // Keyboard/VoiceOver parallel to the sidebar's mouse-only collection drag —
    // only meaningful when the Collections section is shown, in Manual sort,
    // with a collection open (the active one is the move target).
    private var sidebarManualMoveEnabled: Bool {
        AppSettings.showCollectionsInSidebar
            && appState.sidebarCollectionSortMode == .manual
            && appState.activeCollectionID != nil
    }
    private var sidebarActiveCollectionIndex: Int? {
        guard let id = appState.activeCollectionID else { return nil }
        return appState.sidebarCollections.firstIndex { $0.collection.id == id }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(googleAuth)
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
                    // Hard-delete any Drive shares past their expiry (no-op if
                    // not signed in or nothing is due).
                    await DriveExpirySweeper.sweep(auth: googleAuth)
                }
        }
        .commands {
            // "Check for Updates…" sits in the Muse app menu, right below
            // "About Muse" — the conventional spot every Mac app uses.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater.controller.updater)
                Divider()
                Button("Back Up Muse…") { appState.exportBackup() }
                Button("Restore from Backup…") { appState.beginRestorePicker() }
            }

            // Settings is an in-app modal sheet (dimmed + centered like the
            // other modals), not the native Preferences window, so replace the
            // standard "Settings…" item with one that opens the sheet (⌘,).
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appState.settingsShown = true }
                    .keyboardShortcut(",", modifiers: .command)
            }

            // Folder actions on the current selection live in the Edit menu.
            // Image selection commands, like Finder's Edit menu.
            CommandGroup(after: .pasteboard) {
                Button("Select All") {
                    // If a text field (e.g. the search box) has focus, ⌘A must
                    // select its text, like every Mac app — not the grid images.
                    if let editor = NSApp.keyWindow?.firstResponder as? NSText {
                        editor.selectAll(nil)
                    } else {
                        appState.selectAllVisible()
                    }
                }
                .keyboardShortcut("a", modifiers: .command)
                Button("Deselect All") { appState.clearSelection() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(appState.selectedFiles.isEmpty)
            }

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

                // Keyboard/menu parallel to the sidebar's mouse-only
                // drag-to-reorder (closes the reorder accessibility gap).
                Button("Move Folder Up") { moveSelectedRoot(by: -1) }
                    .disabled(!canReorderSelectedRoot || (selectedRootIndex ?? 0) <= 0)
                Button("Move Folder Down") { moveSelectedRoot(by: 1) }
                    .disabled(!canReorderSelectedRoot
                              || selectedRootIndex == nil
                              || selectedRootIndex! >= displayedReorderableRoots.count - 1)

                Button("Set as Collection Cover") {
                    if let file = appState.selectedFile {
                        appState.setCollectionCover(file)
                    }
                }
                .disabled(appState.activeCollectionID == nil || appState.selectedFile == nil)

                Divider()

                Button("New Subfolder…") {
                    if let folder = appState.selectedFolder {
                        appState.requestNewSubfolder(folder)
                    }
                }
                .disabled(appState.selectedFolder == nil)

                Button("Rename Folder…") {
                    if let folder = appState.selectedFolder {
                        appState.requestRenameFolder(folder)
                    }
                }
                .disabled(appState.selectedFolder == nil
                          || appState.selectedFolder?.url == appState.iCloudFolderURL)
            }

            // Library tools live in the File menu.
            CommandGroup(after: .newItem) {
                Divider()
                Button("Find Duplicates in Folder") {
                    appState.findDuplicatesInCurrentFolder()
                }

                Divider()

                Button("Open") {
                    if let url = appState.selectedFile?.url { NSWorkspace.shared.open(url) }
                }
                .disabled(appState.selectedFile == nil)

                Menu("Open With") {
                    if let url = appState.selectedFile?.url {
                        ForEach(OpenWithMenu.applications(for: url), id: \.self) { appURL in
                            Button(appURL.deletingPathExtension().lastPathComponent) {
                                NSWorkspace.shared.open(
                                    [url], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                            }
                        }
                    }
                }
                .disabled(appState.selectedFile == nil)
            }

            // Menu-bar equivalents of the chip context menu — keyboard and
            // VoiceOver reachable. Enabled while a tag filter is selected.
            CommandMenu("Tags") {
                Button("Rename Tag…") {
                    if let label = appState.singleActiveTag {
                        appState.tagRenameRequest = label
                    }
                }
                .disabled(appState.singleActiveTag == nil)

                Button("Delete Tag…") {
                    if let label = appState.singleActiveTag {
                        appState.tagDeleteRequest = label
                    }
                }
                .disabled(appState.singleActiveTag == nil)

                Button("Remove Tag from Selection") {
                    if let label = appState.singleActiveTag {
                        appState.removeTag(label,
                                           fromURLs: appState.effectiveSelectionURLs(fallback: ""))
                    }
                }
                .disabled(appState.singleActiveTag == nil || appState.selectedFiles.isEmpty
                          || appState.isSearchActive)

                Divider()

                Button("Clear Tag Filter") {
                    appState.setActiveTag(nil)
                }
                .disabled(appState.activeTagLabels.isEmpty)

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
                // Keyboard/VoiceOver parallel to the grid right-click's "New
                // Collection from Selection" (which is otherwise mouse-only).
                Button("New Collection from Selection…") {
                    appState.requestNewCollection(fallback: "")
                }
                .disabled(appState.selectedFiles.isEmpty)

                Divider()

                Button("Rename Collection…") {
                    appState.collectionRenameRequest = true
                }
                .disabled(appState.activeCollectionID == nil)

                Button("Delete Collection…") {
                    appState.collectionDeleteRequest = true
                }
                .disabled(appState.activeCollectionID == nil)

                // Sidebar-only manual reorder (parallels the mouse-only drag).
                Button("Move Collection Up") {
                    if let id = appState.activeCollectionID {
                        appState.moveSidebarCollection(id: id, by: -1)
                    }
                }
                .disabled(!sidebarManualMoveEnabled || (sidebarActiveCollectionIndex ?? 0) <= 0)

                Button("Move Collection Down") {
                    if let id = appState.activeCollectionID {
                        appState.moveSidebarCollection(id: id, by: 1)
                    }
                }
                .disabled(!sidebarManualMoveEnabled
                          || sidebarActiveCollectionIndex == nil
                          || (sidebarActiveCollectionIndex ?? Int.max)
                             >= appState.sidebarCollections.count - 1)

                Button("Remove Selection from Collection") {
                    if let cid = appState.activeCollectionID {
                        appState.removeFromCollection(cid,
                                                      urls: appState.effectiveSelectionURLs(fallback: ""))
                    }
                }
                .disabled(appState.activeCollectionID == nil || appState.selectedFiles.isEmpty
                          || appState.isSearchActive)

                Divider()

                Button("Back to Library") {
                    appState.setActiveCollection(nil)
                }
                .disabled(appState.activeCollectionID == nil)
            }
        }
        // Settings is presented as an in-app modal sheet from ContentView
        // (see AppState.settingsShown), not the native Preferences window.
    }
}
