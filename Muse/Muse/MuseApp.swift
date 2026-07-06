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
    /// Last responder in the chain for the standard Edit-menu "Select All"
    /// (and its menu validation) — see `AppDelegate` below.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    /// Sparkle self-updater (direct-distribution build only). Started at
    /// launch so background checks honor the user's preference.
    @StateObject private var updater = UpdaterController()
    /// Shared Google sign-in for the Drive share feature — one instance for the
    /// share UI, the Manage sheet, and the launch expiry sweep.
    @StateObject private var googleAuth = GoogleOAuth()

    /// Pin / Unpin label reflects the selected folder's current state.
    private var pinMenuTitle: String {
        // String-typed property, so these literals aren't in an extractable
        // SwiftUI position — hand-wrap each or they ship in English.
        guard let folder = appState.selectedFolder else { return String(localized: "Pin Folder") }
        return appState.stars.isStarred(folder.url)
            ? String(localized: "Unpin Folder") : String(localized: "Pin Folder")
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
                .onAppear { appDelegate.appState = appState }
                .task {
                    ThumbnailCache.shared.enforceDiskCap()
                    // 180-day retention for data of removed folders.
                    if let queue = Database.shared.dbQueue {
                        let persisted = appState.bookmarks.roots
                        let resolved = persisted
                            .compactMap { $0.resolveURL()?.standardizedFileURL.path }
                        // Fail closed: a root that can't resolve right now
                        // (unplugged volume, stale bookmark) would read as
                        // "unreachable" and get its whole subtree hard-deleted
                        // — skip this launch instead. Same guard class as
                        // PathReconciler.rootReachable, but for a permanent
                        // DELETE, so the bar is stricter: ALL roots must
                        // resolve before any prune runs.
                        if resolved.count == persisted.count {
                            // The iCloud "Muse" root is never a bookmark root;
                            // resolve it directly (off-main — first container
                            // access can block) rather than trusting the
                            // async-discovered appState.iCloudFolderURL, which
                            // may not be populated yet this early in launch.
                            let icloud = await Task.detached(priority: .utility) {
                                ICloudZone.folderURL()?.standardizedFileURL.path
                            }.value
                            await Housekeeping.pruneUnreachable(queue: queue,
                                                                rootPaths: resolved,
                                                                icloudRoot: icloud)
                        }
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
            //
            // We do NOT add our own "Select All": SwiftUI's standard Edit menu
            // already provides one (routed through the AppKit responder chain),
            // and adding a second produced a confusing duplicate. Instead the
            // AppDelegate implements `selectAll(_:)` so the system item drives
            // the grid (the field editor still wins ⌘A while a text field is
            // focused). Only "Deselect All" is bespoke (no system equivalent).
            CommandGroup(after: .pasteboard) {
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
                // Scoped to a folder — during search `currentFiles` is the
                // (cross-folder) search result set, not a folder, so the scan
                // would betray the "in Folder" label. Disable, matching the
                // other folder-scoped commands.
                .disabled(appState.isSearchActive)

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

            // View menu — the global Drive share list (not tied to a folder).
            CommandGroup(after: .sidebar) {
                Button {
                    appState.driveSharesShown = true
                } label: {
                    Label("Manage Drive Shares…", systemImage: "link")
                }
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
                    appState.requestRenameActiveCollection()
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

            // Menu-bar equivalent of the tile's Rating context menu so rating
            // isn't mouse/right-click-only (keyboard + VoiceOver). Targets the
            // current selection, mirroring "New Collection from Selection…".
            // ⌘0 clears, ⌘1–⌘5 set (Apple Photos convention).
            CommandMenu("Rating") {
                Button("No Rating") {
                    appState.setRating(nil, forSelectionFallback: "")
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(appState.selectedFiles.isEmpty)

                Divider()

                ForEach(1...StarRating.maxStars, id: \.self) { n in
                    Button(StarRating.label(for: n) ?? "") {
                        appState.setRating(n, forSelectionFallback: "")
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                    .disabled(appState.selectedFiles.isEmpty)
                    .accessibilityLabel(Text(String(format: NSLocalizedString(
                        "%lld-star rating",
                        comment: "VoiceOver: star rating of a photo"), n)))
                }
            }
        }
        // Settings is presented as an in-app modal sheet from ContentView
        // (see AppState.settingsShown), not the native Preferences window.
    }
}

/// Minimal app delegate that exists solely to back the standard Edit-menu
/// "Select All" for the image grid. SwiftUI auto-generates that menu item and
/// routes its `selectAll(_:)` action through the AppKit responder chain; the
/// SwiftUI grid isn't an AppKit responder, so without this the item stayed
/// permanently disabled (and we'd added a confusing second, custom "Select
/// All" to compensate). The delegate is the last link in the responder chain,
/// so a focused text field's field editor still wins ⌘A (selecting its text);
/// only when nothing else handles it does the grid select-all run.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    weak var appState: AppState?

    // Supplying a custom delegate drops SwiftUI's default; keep secure state
    // restoration on (avoids the "secure coding not enabled" runtime warning).
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func selectAll(_ sender: Any?) {
        appState?.selectAllVisible()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(selectAll(_:)) {
            return !(appState?.visibleFiles.isEmpty ?? true)
        }
        return true
    }
}
