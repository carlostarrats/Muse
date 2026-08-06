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

    /// Commerce + announcements are their own stores — AppState is frozen
    /// (DECIDED #26), so new features never grow it. Same injection pattern as
    /// googleAuth above.
    @StateObject private var commerceStore = CommerceStore()
    @StateObject private var announcementStore = AnnouncementStore()
    @StateObject private var welcomeStore: WelcomeOnboardingStore
    /// Observed so Help ▸ Welcome to Muse disables itself while Compare owns
    /// the window, rather than opening a content-column card underneath it.
    @StateObject private var compareStore = CompareStore.shared
    /// Observed so the View menu's hide-UI item can title and enable itself
    /// from the editor's state. See `EditorChromeCommand`.
    ///
    /// `@StateObject`, like every other object here — that is the shape already
    /// proven to re-evaluate this file's `Commands` body (the Drive and
    /// Open With items disable themselves off `appState` the same way). The
    /// autoclosure runs once and hands back the singleton.
    @StateObject private var editorChrome = EditorChromeCommand.shared
    /// Observed so the Editor Workspace submenu can disable itself while a
    /// reorder owns the editor.
    @StateObject private var editorWorkspace = EditorWorkspaceStore.shared

    /// Pin / Unpin label reflects the selected folder's current state.
    private var pinMenuTitle: String {
        // String-typed property, so these literals aren't in an extractable
        // SwiftUI position — hand-wrap each or they ship in English.
        guard let folder = appState.selectedFolder else { return String(localized: "Pin Folder") }
        return appState.stars.isStarred(folder.url)
            ? String(localized: "Unpin Folder") : String(localized: "Pin Folder")
    }

    /// Menu icon paired with `pinMenuTitle`, so the glyph tracks the verb.
    private var pinMenuIcon: String {
        guard let folder = appState.selectedFolder else { return "pin" }
        return appState.stars.isStarred(folder.url) ? "pin.slash" : "pin"
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

    init() {
        #if DEBUG
        if let suiteName = WelcomeDefaultsSuiteArgument.suiteName(
                in: ProcessInfo.processInfo.arguments),
           let defaults = UserDefaults(suiteName: suiteName) {
            _welcomeStore = StateObject(
                wrappedValue: WelcomeOnboardingStore(defaults: defaults))
        } else {
            _welcomeStore = StateObject(wrappedValue: WelcomeOnboardingStore())
        }
        #else
        _welcomeStore = StateObject(wrappedValue: WelcomeOnboardingStore())
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // The window had no minimum at all, so it could be dragged
                // narrower than the hero viewer's fixed 258pt info column and
                // the photo ended up drawn over it. See ViewerGeometry.
                .frame(minWidth: ViewerGeometry.minWindowWidth,
                       minHeight: ViewerGeometry.minWindowHeight)
                .environmentObject(appState)
                .environmentObject(googleAuth)
                .environmentObject(commerceStore)
                .environmentObject(announcementStore)
                .environmentObject(welcomeStore)
                .onAppear { appDelegate.appState = appState }
                .task {
                    // Decide before every other launch effect. An automatic
                    // welcome is the only launch modal and skips the
                    // announcement request entirely for this run.
                    let welcomeEffects = welcomeStore.prepareForLaunch(
                        hasStoredUserFolder: !appState.bookmarks.roots.isEmpty)
                    PhaseTrace.begin()
                    ThumbnailCache.shared.enforceDiskCap()
                    // Rendered export temps: bounded by age, not size. The
                    // consumers collect their own temps now, so this is the
                    // backstop for an INTERRUPTED publish or share (and for
                    // the share sheet, which reads its files lazily). Detached
                    // — it enumerates and deletes a directory, which has no
                    // business on the main thread during launch.
                    Task.detached(priority: .background) {
                        OutputRender.sweepRenderTemps()
                    }
                    // BEFORE the backfills: every pixel consumer consults the
                    // index, and a thumbnail generated in the window before
                    // it's installed would be cached under the unedited key.
                    EditStackIndex.installProvider(LiveEditStackProvider())
                    EditStore.shared.installHost(appState)
                    AnalysisStatusStore.shared.installHost(appState)
                    AnalysisStatusStore.shared.refresh(force: true)
                    PhaseTrace.mark("edit-index.start")
                    let editIndexWarm = Task {
                        await EditStore.shared.rebuildIndex()
                        PhaseTrace.mark("edit-index.end")
                    }
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
                    // ONE chain for every launch backfill, at `.utility`, after
                    // the edit index is warm. They used to be four independent
                    // `Task {}`s that started together and contended for the
                    // single GRDB serial queue — the same queue the first
                    // folder open needs. See LaunchBackfills for the ordering
                    // rationale; foundation §9 is what decides the shape.
                    Task(priority: .utility) {
                        await editIndexWarm.value
                        await LaunchBackfills.run()
                    }
                    // Developer perf harness. Env-gated like PhaseTrace, so a
                    // shipped run never reaches it.
                    if PerfBaseline.enabled {
                        Task { _ = await PerfBaseline.run() }
                    }
                    // Announcements: one GET of a static file per launch,
                    // off-able in Settings (which disables the fetch itself).
                    if welcomeEffects.shouldFetchAnnouncements {
                        Task { await announcementStore.fetchIfNeeded() }
                    }
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
                Button { appState.exportBackup() } label: {
                    Label("Back Up Muse…", systemImage: "arrow.down.doc")
                }
                Button { appState.beginRestorePicker() } label: {
                    Label("Restore from Backup…", systemImage: "arrow.up.doc")
                }
            }

            // Settings is an in-app modal sheet (dimmed + centered like the
            // other modals), not the native Preferences window, so replace the
            // standard "Settings…" item with one that opens the sheet (⌘,).
            CommandGroup(replacing: .appSettings) {
                Button { appState.settingsShown = true } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
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
                Button { appState.clearSelection() } label: {
                    Label("Deselect All", systemImage: "rectangle.dashed")
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(appState.selectedFiles.isEmpty)
            }

            // Edit-stack copy/paste. The menu items exist so the shortcuts are
            // discoverable and so the actions have a keyboard path outside the
            // editor's own chrome; Paste applies to the grid selection, which
            // is the same batch sync the context menu offers.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Paste Adjustments") {
                    guard let source = EditClipboard.shared.stack else { return }
                    let groups = EditClipboard.shared.groups
                    let targets = appState.effectiveSelectionURLs(fallback: "")
                        .filter {
                            let kind = AssetKind.detect(at: $0)
                            return kind == .image || kind == .raw
                        }
                    Task {
                        await EditStore.shared.applyToAll(
                            { EditTransfer.apply(groups: groups, from: source, onto: $0) },
                            urls: targets)
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!EditClipboard.shared.hasContent || appState.selectedFiles.isEmpty)
            }

            CommandGroup(after: .pasteboard) {
                Divider()
                Button {
                    if let folder = appState.selectedFolder {
                        appState.toggleStar(folder: folder)
                    }
                } label: {
                    Label(pinMenuTitle, systemImage: pinMenuIcon)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(appState.selectedFolder == nil)

                // No shortcut: removing a root is destructive-adjacent and rare.
                Button {
                    if let root = selectedRoot {
                        appState.removeRoot(root)
                    }
                } label: {
                    Label("Remove Folder", systemImage: "minus.rectangle")
                }
                .disabled(selectedRoot == nil)

                // Keyboard/menu parallel to the sidebar's mouse-only
                // drag-to-reorder (closes the reorder accessibility gap).
                Button { moveSelectedRoot(by: -1) } label: {
                    Label("Move Folder Up", systemImage: "arrow.up")
                }
                .disabled(!canReorderSelectedRoot || (selectedRootIndex ?? 0) <= 0)
                Button { moveSelectedRoot(by: 1) } label: {
                    Label("Move Folder Down", systemImage: "arrow.down")
                }
                    .disabled(!canReorderSelectedRoot
                              || selectedRootIndex == nil
                              || selectedRootIndex! >= displayedReorderableRoots.count - 1)

                Button {
                    if let file = appState.selectedFile {
                        appState.setCollectionCover(file)
                    }
                } label: {
                    Label("Set as Collection Cover", systemImage: "photo.badge.checkmark")
                }
                .keyboardShortcut("c", modifiers: [.command, .control])
                .disabled(appState.activeCollectionID == nil || appState.selectedFile == nil)

                Divider()

                Button {
                    if let folder = appState.selectedFolder {
                        appState.requestNewSubfolder(folder)
                    }
                } label: {
                    Label("New Subfolder…", systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("n", modifiers: [.command, .control])
                .disabled(appState.selectedFolder == nil)

                Button {
                    if let folder = appState.selectedFolder {
                        appState.requestRenameFolder(folder)
                    }
                } label: {
                    Label("Rename Folder…", systemImage: "pencil")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.selectedFolder == nil
                          || appState.selectedFolder?.url == appState.iCloudFolderURL)
            }

            // Library tools live in the File menu.
            CommandGroup(after: .newItem) {
                Divider()
                Button {
                    let urls = appState.effectiveSelectionURLs(fallback: "")
                    guard appState.selectedFile == nil,
                          (2...CompareStore.maxPanes).contains(urls.count) else { return }
                    CompareStore.shared.open(urls: Array(urls))
                } label: {
                    Label("Compare Side by Side", systemImage: "rectangle.split.2x1")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(appState.selectedFile != nil
                          || !(2...CompareStore.maxPanes)
                              .contains(appState.effectiveSelectionURLs(fallback: "").count))

                Divider()
                // Export from the keyboard, wherever you are. The open photo
                // wins when the viewer or editor is up; otherwise it's the grid
                // selection. Without this the only way in was a context menu or
                // the viewer's share button, which is a poor showing for the
                // one action that gets a file out of the app.
                Button {
                    let urls = appState.exportableSelectionURLs()
                    guard !urls.isEmpty else { return }
                    appState.exportRequest = ExportRequest(urls: urls)
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up.on.square")
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!appState.hasExportableSelection)

                Divider()
                Button {
                    appState.findDuplicatesInCurrentFolder()
                } label: {
                    Label("Find Duplicates in Folder", systemImage: "square.on.square")
                }
                .keyboardShortcut("d", modifiers: .command)
                // Scoped to a folder — during search `currentFiles` is the
                // (cross-folder) search result set, not a folder, so the scan
                // would betray the "in Folder" label. Disable, matching the
                // other folder-scoped commands.
                .disabled(appState.isSearchActive)

                // One Import surface over every source. An item whose
                // dependency isn't built is ABSENT, never disabled — a
                // greyed-out row promises something that isn't coming.
                Menu {
                    Button {
                        appState.importMetadataAndEdits()
                    } label: {
                        Label("Metadata & Lightroom Edits…", systemImage: "square.and.arrow.down")
                    }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    Button {
                        appState.importLightroomPresets()
                    } label: {
                        Label("Lightroom Presets…", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        appState.importApplePhotos()
                    } label: {
                        Label("From Apple Photos…", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        appState.importGoogleTakeout()
                    } label: {
                        Label("From Google Takeout…", systemImage: "shippingbox")
                    }
                    Button {
                        appState.importEagleLibrary()
                    } label: {
                        Label("From Eagle Library…", systemImage: "tray.full")
                    }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }

                Divider()

                Button {
                    if let url = appState.selectedFile?.url { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
                .disabled(appState.selectedFile == nil)

                Menu {
                    if let url = appState.selectedFile?.url {
                        ForEach(OpenWithMenu.applications(for: url), id: \.self) { appURL in
                            Button(appURL.deletingPathExtension().lastPathComponent) {
                                NSWorkspace.shared.open(
                                    [url], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                            }
                        }
                    }
                } label: {
                    Label("Open With", systemImage: "app.badge")
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
                .keyboardShortcut("l", modifiers: [.command, .shift])

                // The editor's hide-UI eye, in the menu bar — which is where a
                // Mac user goes to LEARN a shortcut, and the reason ⌘U isn't
                // just an undiscoverable key on the button.
                //
                // Disabled outside Edit mode: `uiHidden` is nil when no editor
                // is on screen. The title follows the state, like Apple's own
                // Hide/Show Toolbar, so the item always names what it will do.
                //
                // Not ⌘⇧H — a three-key chord for a control you bounce on, and
                // a slip off the shift hides the app. Nothing in Muse or macOS
                // claims ⌘U (this app has no Format menu), and its neighbours
                // ⌘Y/⌘I/⌘J are unbound too, so a miss does nothing.
                Button {
                    EditorChromeCommand.shared.requestToggle()
                } label: {
                    if editorChrome.uiHidden == true {
                        Label("Show controls", systemImage: "eye")
                    } else {
                        Label("Hide controls", systemImage: "eye.slash")
                    }
                }
                .keyboardShortcut("u", modifiers: .command)
                // Also off while a card is up. Muse's modals are in-window
                // overlays, so a key equivalent still reaches the menu — and
                // hiding the chrome UNDER an open export card or name prompt
                // leaves the UI gone for a reason the user never saw.
                .disabled(editorChrome.uiHidden == nil || appState.modalPresented
                          || editorWorkspace.reorderMode)

                Divider()

                // The editor's panel layout. Named "Editor Workspace" — a
                // noun, the editor's workspace. "Edit Workspace" reads as a
                // verb, which is exactly wrong for a submenu that contains an
                // actual Customize item.
                //
                // There is deliberately NO "Single Column" item. Single column
                // is the state where one column is empty, reached by dragging.
                // A toggle that restored "your last two-column arrangement"
                // would force two arrangements to exist at once, one of them
                // always invisible to the user, plus rules for which one a
                // reset applies to — state bought for a flip nobody performs.
                //
                // No keyboard shortcuts either: none of the three is a control
                // you bounce on.
                Menu {
                    Button {
                        EditorWorkspaceStore.shared.resetToDefault()
                    } label: {
                        Label("Default Layout", systemImage: "arrow.counterclockwise")
                    }
                    Button {
                        EditorWorkspaceStore.shared.customizeShown = true
                    } label: {
                        Label("Customize Modules…", systemImage: "checklist")
                    }
                    Button {
                        EditorWorkspaceStore.shared.beginReorder()
                    } label: {
                        Label("Reorder Modules", systemImage: "arrow.up.arrow.down")
                    }
                } label: {
                    Label("Editor Workspace", systemImage: "rectangle.split.2x1")
                }
                // Off outside Edit mode (uiHidden is nil when no editor is on
                // screen), behind any modal, and during a reorder — the mode
                // owns the editor until it is saved or cancelled.
                .disabled(editorChrome.uiHidden == nil || appState.modalPresented
                          || editorWorkspace.reorderMode)
            }

            // Menu-bar equivalents of the chip context menu — keyboard and
            // VoiceOver reachable. Enabled while a tag filter is selected.
            CommandMenu("Tags") {
                Button {
                    if let label = appState.singleActiveTag {
                        appState.tagRenameRequest = label
                    }
                } label: {
                    Label("Rename Tag…", systemImage: "pencil")
                }
                .keyboardShortcut("r", modifiers: [.command, .control])
                // A rating chip can be the single active tag, and rename is
                // library-wide — renaming "★★★" would wipe every three-star
                // rating. The chip's own context menu hides the item for the
                // same reason; this is the menu-bar/keyboard twin of that.
                .disabled(appState.singleActiveTag.map(StarRating.isRating) ?? true)

                // No shortcut on the destructive tag commands below: a stray
                // chord shouldn't be able to wipe a tag off the whole library.
                Button {
                    if let label = appState.singleActiveTag {
                        appState.tagDeleteRequest = label
                    }
                } label: {
                    Label("Delete Tag…", systemImage: "trash")
                }
                .disabled(appState.singleActiveTag == nil)

                Button {
                    if let label = appState.singleActiveTag {
                        appState.removeTag(label,
                                           fromURLs: appState.effectiveSelectionURLs(fallback: ""))
                    }
                } label: {
                    Label("Remove Tag from Selection", systemImage: "tag.slash")
                }
                .disabled(appState.singleActiveTag == nil || appState.selectedFiles.isEmpty
                          || appState.isSearchActive)

                Divider()

                Button {
                    appState.setActiveTag(nil)
                } label: {
                    Label("Clear Tag Filter", systemImage: "line.3.horizontal.decrease.circle.fill")
                }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(appState.activeTagLabels.isEmpty)

                Divider()

                Button {
                    appState.deleteAllTagsRequest = true
                } label: {
                    Label("Delete All Tags…", systemImage: "trash.slash")
                }
                .disabled(!appState.bulkTagCommandsAvailable)

                Button {
                    appState.regenerateTagsRequest = true
                } label: {
                    Label("Regenerate Tags…", systemImage: "arrow.clockwise")
                }
                .disabled(!appState.bulkTagCommandsAvailable)
            }

            // Same for collections — enabled while inside one.
            CommandMenu("Collections") {
                // Keyboard/VoiceOver parallel to the grid right-click's "New
                // Collection from Selection" (which is otherwise mouse-only).
                Button {
                    appState.requestNewCollection(fallback: "")
                } label: {
                    Label("New Collection from Selection…", systemImage: "rectangle.stack.badge.plus")
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(appState.selectedFiles.isEmpty)

                Divider()

                Button {
                    appState.requestRenameActiveCollection()
                } label: {
                    Label("Rename Collection…", systemImage: "pencil")
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(appState.activeCollectionID == nil)

                // Destructive — no shortcut, same rule as the tag deletes.
                Button {
                    appState.collectionDeleteRequest = true
                } label: {
                    Label("Delete Collection…", systemImage: "trash")
                }
                .disabled(appState.activeCollectionID == nil)

                // Sidebar-only manual reorder (parallels the mouse-only drag).
                Button {
                    if let id = appState.activeCollectionID {
                        appState.moveSidebarCollection(id: id, by: -1)
                    }
                } label: {
                    Label("Move Collection Up", systemImage: "arrow.up")
                }
                .disabled(!sidebarManualMoveEnabled || (sidebarActiveCollectionIndex ?? 0) <= 0)

                Button {
                    if let id = appState.activeCollectionID {
                        appState.moveSidebarCollection(id: id, by: 1)
                    }
                } label: {
                    Label("Move Collection Down", systemImage: "arrow.down")
                }
                .disabled(!sidebarManualMoveEnabled
                          || sidebarActiveCollectionIndex == nil
                          || (sidebarActiveCollectionIndex ?? Int.max)
                             >= appState.sidebarCollections.count - 1)

                Button {
                    if let cid = appState.activeCollectionID {
                        appState.removeFromCollection(cid,
                                                      urls: appState.effectiveSelectionURLs(fallback: ""))
                    }
                } label: {
                    Label("Remove Selection from Collection", systemImage: "rectangle.stack.badge.minus")
                }
                .disabled(appState.activeCollectionID == nil || appState.selectedFiles.isEmpty
                          || appState.isSearchActive)

                Divider()

                Button {
                    appState.setActiveCollection(nil)
                } label: {
                    Label("Back to Library", systemImage: "photo.on.rectangle")
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(appState.activeCollectionID == nil)
            }

            // Bundled into one Commands value to stay below the CommandsBuilder
            // top-level arity limit while still placing each item in its native
            // menu.
            RatingAndWelcomeCommands(appState: appState,
                                     welcomeStore: welcomeStore,
                                     compareStore: compareStore)
        }
        // Settings is presented as an in-app modal sheet from ContentView
        // (see AppState.settingsShown), not the native Preferences window.
    }
}

/// The Rating menu plus the welcome item in Help. Keeping these in one Commands
/// value avoids growing MuseApp's already-wide top-level commands builder.
private struct RatingAndWelcomeCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject var welcomeStore: WelcomeOnboardingStore
    @ObservedObject var compareStore: CompareStore

    var body: some Commands {
        // Menu-bar equivalent of the tile's Rating context menu so rating isn't
        // mouse/right-click-only (keyboard + VoiceOver). ⌘0 clears, ⌘1–⌘5 set.
        CommandMenu("Rating") {
            Button {
                appState.setRating(nil, forSelectionFallback: "")
            } label: {
                Label("No Rating", systemImage: "star.slash")
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(appState.selectedFiles.isEmpty)

            Divider()

            ForEach(1...StarRating.maxStars, id: \.self) { n in
                Button {
                    appState.setRating(n, forSelectionFallback: "")
                } label: {
                    Label(StarRating.label(for: n) ?? "", systemImage: "star.fill")
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                .disabled(appState.selectedFiles.isEmpty)
                .accessibilityLabel(Text(String(format: NSLocalizedString(
                    "%lld-star rating",
                    comment: "VoiceOver: star rating of a photo"), n)))
            }
        }

        CommandGroup(after: .help) {
            Button("Welcome to Muse") {
                welcomeStore.presentManually()
            }
            .disabled(!WelcomePresentationRules.canPresentManually(
                appModalPresented: appState.modalPresented,
                welcomePresented: welcomeStore.isPresented,
                viewerPresented: appState.selectedFile != nil,
                comparePresented: compareStore.isActive))
        }
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
