//
//  ContentView.swift
//  Muse
//
//  Phase 3 main shell: NavigationSplitView with sidebar + grid +
//  optional right detail panel + breadcrumb/sort/analyze toolbar.
//  Selected file pops up the viewer overlay via ViewerRouter.
//

import SwiftUI
import AppKit

/// Scope tag for the native `.searchScopes` picker. Distinct from `SearchScope`
/// (the SearchService enum that carries a folder URL) — this is just the UI
/// choice, mapped to `AppState.searchAllFolders`.
private enum SearchFolderScope: Hashable {
    case all, thisFolder
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject private var googleAuth: GoogleOAuth
    @EnvironmentObject private var announcementStore: AnnouncementStore
    @ObservedObject private var indexProgress = IndexProgress.shared
    @ObservedObject private var analyzePipeline = AnalyzePipeline.shared
    /// Unified background-progress state driving the single status pill.
    @State private var workProgress = WorkProgress()
    /// Guards against queueing a second completion hold while one is running.
    @State private var finishHoldScheduled = false
    @ObservedObject private var collectionsEngine = CollectionsEngine.shared
    @State private var moodPickerShown = false
    /// Tags from visually similar photos, for the Add Tag card's offer row.
    @State private var similarTags: [TagSuggest.Candidate] = []
    @State private var filterPopoverShown = false

    /// Close whichever modal is up. Only one is ever presented at a time, so
    /// this is a deterministic sweep rather than a real stack.
    private func dismissTopModal() {
        // Confirms/errors first: they're presented outermost, so one raised
        // from inside another card (a delete confirm over Duplicates) is the
        // one on top — Escape has to peel it before its host.
        if let a = announcementStore.pending { announcementStore.dismiss(a.id); return }
        if appState.alertRequest != nil { appState.alertRequest = nil; return }
        if !appState.moveFailureNames.isEmpty { appState.moveFailureNames = []; return }
        if appState.folderOpError != nil { appState.folderOpError = nil; return }
        if appState.backupError != nil { appState.backupError = nil; return }
        if appState.fileRenameError != nil { appState.fileRenameError = nil; return }
        // Name prompts.
        if appState.collectionRenameAlertRequest != nil { appState.collectionRenameAlertRequest = nil; return }
        if appState.fileRenameRequest != nil { appState.fileRenameRequest = nil; return }
        if appState.newSubfolderRequest != nil { appState.newSubfolderRequest = nil; return }
        if appState.folderRenameRequest != nil { appState.folderRenameRequest = nil; return }
        if appState.tagRenameRequest != nil { appState.tagRenameRequest = nil; return }
        if appState.collectionModal != nil { appState.collectionModal = nil; return }
        if appState.addTagRequest != nil { appState.addTagRequest = nil; return }
        if appState.newCollectionRequest { appState.cancelNewCollection(); return }
        if appState.metadataImportRequest != nil { appState.metadataImportRequest = nil; return }
        if appState.reconnectShown { appState.reconnectShown = false; return }
        if appState.duplicatesSheetVisible { appState.duplicatesSheetVisible = false; return }
        if appState.driveSharesShown { appState.driveSharesShown = false; return }
        if appState.settingsShown { appState.settingsShown = false; return }
        if appState.imageLayoutShown { appState.imageLayoutShown = false; return }
        if appState.infoShown { appState.infoShown = false; return }
    }

    /// True while the window is in macOS full-screen — drives the full-screen-only
    /// SwiftUI toolbar hide.
    @State private var isFullScreen = false

    // Native `.searchable` state (replaced the custom centered NSSearchField).
    // `searchText` is the field's live text; it's kept LOCAL so per-keystroke
    // typing re-evaluates only what the binding touches, and the query is pushed
    // to `AppState.searchQuery` + debounced from `handleSearchTextChange`.
    @State private var searchText = ""
    @State private var searchDebounce: Task<Void, Never>?

    /// The Collections page is the card grid — showing collections with no
    /// single collection drilled into (and not while searching).
    private var isCollectionsPage: Bool {
        appState.showingCollections
            && appState.activeCollectionID == nil
            && !appState.isSearchActive
    }

    /// True anywhere in the Collections world — the card page OR drilled into a
    /// single collection (whether opened from the page or the sidebar). Used to
    /// disable controls that make no sense there, like show-subfolders:
    /// collections are a flat membership, not a folder tree.
    private var inCollectionsContext: Bool {
        appState.showingCollections || appState.activeCollectionID != nil
    }

    /// Collections-page⇄grid swap: the outgoing screen is removed INSTANTLY and
    /// only the incoming fades in (over the background). With no overlap, the two
    /// dissimilar layouts never blend into a "ghost" — leaving Collections, the
    /// cards vanish at once and the folder fades up in their place.
    private static var pageReveal: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .identity)
    }

    var body: some View {
        ZStack {
        NavigationSplitView {
            SidebarView()
        } detail: {
            // The OS check must wrap the `.toolbar` APPLICATION, not live inside
            // the builder: any `if #available` (buildLimitedAvailability) anywhere
            // in a toolbar content tree erases the structure SwiftUI uses to
            // resolve `ToolbarSpacer` group breaks — the spacers were silently
            // ignored and every adjacent item fused into one glass capsule
            // (verified live; two builder-level gating shapes both failed). Out
            // here the check costs a Group and each branch hands `.toolbar` a
            // FLAT item list, exactly the shape the API is documented against.
            Group {
                if #available(macOS 26.0, *) {
                    detailCore.toolbar {
                        spacedLeadingA
                        spacedLeadingB
                    }
                    // The empty title area still flexes, shoving the `.automatic`
                    // strip toward the center — removing the title item frees the
                    // controls to sit flush left.
                    .toolbar(removing: .title)
                } else {
                    detailCore.toolbar {
                        plainLeadingA
                        plainLeadingB
                    }
                }
            }
            // Search is a native `.searchable` field (an `NSSearchToolbarItem`):
            // the system pins it at the trailing edge and, when the window
            // narrows, COLLAPSES it to a magnifier icon that expands on click
            // (the Notes/Mail behavior) while the leading buttons roll into the »
            // overflow — instead of the field just vanishing. This replaced the
            // custom centered NSSearchField; the tradeoff is the field no longer
            // mood-tints (it follows the system look). Scope (All / This Folder)
            // is the native `.searchScopes` picker; debounce + query-injection are
            // wired through the onChange handlers below.
            .searchable(text: $searchText,
                        placement: .toolbar,
                        prompt: Text("Search files, tags, captions…"))
            .searchScopes(Binding(
                get: { appState.searchAllFolders ? SearchFolderScope.all : .thisFolder },
                set: { setSearchScope($0) }
            )) {
                Text("All").tag(SearchFolderScope.all)
                Text("This Folder").tag(SearchFolderScope.thisFolder)
            }
            .onChange(of: searchText) { _, newValue in
                handleSearchTextChange(newValue)
            }
            // Programmatic query push (viewer tag taps) or an external clear
            // (folder select) — mirror it into the field, and kill any in-flight
            // debounce on clear so a just-dismissed query doesn't re-fire.
            .onChange(of: appState.searchQuery) { _, newValue in
                if searchText != newValue { searchText = newValue }
                if newValue.isEmpty { searchDebounce?.cancel() }
            }
            // Folder select dismisses search — clear uncommitted local text +
            // the pending debounce (searchQuery may already be "" when nothing
            // was committed, so the sync above can't catch this case).
            .onChange(of: appState.searchDismissToken) { _, _ in
                searchDebounce?.cancel()
                if !searchText.isEmpty { searchText = "" }
            }
            .onSubmit(of: .search) {
                runSearchNow(searchText)
            }
            // Modals are in-window cards, not sheets — see Views/Modal/ModalChrome.
            // Every one is presented HERE, at the shell, because the card is sized
            // from the geometry of whatever it's attached to: presented from a
            // sidebar row it would be laid out against the sidebar's width.
            // Rows of image tiles. Sized to show five tiles per row —
            // 5×140 + 4×12 spacing + the group panel's 20pt and the row
            // scroller's 16pt insets. A longer group scrolls horizontally,
            // which it always did; seven tiles just made the card oversized.
            .museModal(isPresented: $appState.duplicatesSheetVisible,
                       width: 820, palette: appState.moodPalette) {
                DuplicatesView(isPresented: $appState.duplicatesSheetVisible)
            }
            .museModal(isPresented: $appState.infoShown,
                       width: 600, palette: appState.moodPalette) {
                InfoSheet(isPresented: $appState.infoShown)
            }
            // Three 120pt tiles and a subtitle — a 600pt card left it swimming.
            .museModal(isPresented: $appState.imageLayoutShown,
                       width: 460, palette: appState.moodPalette) {
                ImageLayoutSheet(isPresented: $appState.imageLayoutShown)
                    .environmentObject(appState)
            }
            // Form rows with long explanatory footers.
            .museModal(isPresented: $appState.settingsShown,
                       width: 560, palette: appState.moodPalette) {
                SettingsView(isPresented: $appState.settingsShown)
                    .environmentObject(appState)
            }
            // A list of share rows: name, date, two buttons.
            .museModal(isPresented: $appState.driveSharesShown,
                       width: 520, palette: appState.moodPalette) {
                ManageDriveSharesView()
            }
            .museModal(isPresented: Binding(
                get: { appState.metadataImportRequest != nil },
                set: { if !$0 { appState.metadataImportRequest = nil } }),
                       width: 360, palette: appState.moodPalette) {
                if let request = appState.metadataImportRequest {
                    MetadataImportSheet(request: request)
                        .environmentObject(appState)
                }
            }
            // Add Tag / New Collection: a field plus a live-filtered list of
            // what already exists, so you pick "sunset" instead of minting
            // "Sunsets". These were `.alert`s, which can host only TextFields
            // and Buttons — a suggestion list can't live inside one.
            .museModal(isPresented: Binding(
                get: { appState.addTagRequest != nil },
                set: { if !$0 { appState.addTagRequest = nil } }),
                       width: 380, palette: appState.moodPalette) {
                if let request = appState.addTagRequest {
                    SuggestingNameCard(
                        title: String(localized: "Add Tag"),
                        subtitle: String(localized: "Tags \(request.displayName)."),
                        placeholder: String(localized: "Tag name"),
                        candidates: tagSuggestCandidates,
                        suggestions: similarTags,
                        displaying: { VocabularyLocalizer.shared.display($0) },
                        confirmTitle: String(localized: "Add"),
                        onCommit: { appState.confirmAddTag(label: $0) },
                        onCancel: { appState.addTagRequest = nil })
                    // Keyed on the request so re-opening for a different
                    // selection rebuilds the card with a fresh empty draft.
                    .id(request.id)
                    .task(id: request.id) { await loadSimilarTags(for: request) }
                }
            }
            .museModal(isPresented: Binding(
                get: { appState.newCollectionRequest },
                set: { if !$0 { appState.cancelNewCollection() } }),
                       width: 380, palette: appState.moodPalette) {
                SuggestingNameCard(
                    title: String(localized: "Name Collection"),
                    subtitle: appState.pendingNewCollectionPaths.isEmpty
                        ? String(localized: "Creates a new collection.")
                        : String(localized: "Creates a collection from the selected images."),
                    placeholder: String(localized: "Collection name"),
                    candidates: collectionSuggestCandidates,
                    // No suggestion row here: "which collection is like this
                    // one?" has no meaning, and the field's inline completion
                    // already surfaces the names in use.
                    confirmTitle: String(localized: "Create"),
                    // Committing a name that already exists ADDS to that
                    // collection instead of minting a second one with the same
                    // name — see confirmNewCollection. That's the whole point of
                    // showing the list.
                    onCommit: { appState.confirmNewCollection(name: $0) },
                    onCancel: { appState.cancelNewCollection() })
            }
            .museModal(isPresented: $appState.reconnectShown,
                       width: 600, palette: appState.moodPalette) {
                if let model = appState.reconnectModel {
                    ReconnectWizard(model: model, isPresented: $appState.reconnectShown,
                                    bookmarks: appState.bookmarks)
                }
            }
            // Collection-scoped modals, raised here from the sidebar row / the
            // Collections page / the share button — see CollectionModal.
            .museModal(isPresented: Binding(
                get: { appState.collectionModal != nil },
                set: { if !$0 { appState.collectionModal = nil } }),
                       width: appState.collectionModal?.width ?? 480,
                       palette: appState.moodPalette) {
                switch appState.collectionModal {
                case .customize(let loaded):
                    CustomizeCollectionSheet(loaded: loaded) {
                        appState.collectionModal = nil
                    }
                case .rules(let request):
                    SmartCollectionRulesView(
                        collectionID: request.collectionID,
                        initialName: request.initialName,
                        initialSet: request.initialSet,
                        isConversion: request.isConversion,
                        memberCount: request.memberCount) {
                            appState.collectionModal = nil
                        }
                case .driveShare(let title, let urls):
                    DriveShareSheet(auth: googleAuth, title: title, urls: urls) {
                        appState.collectionModal = nil
                    }
                case .none:
                    EmptyView()
                }
            }
            .modifier(ShellErrorModals())
            .modifier(TagCommandAlerts())
            // Name prompts (rename collection / file / folder, new subfolder,
            // rename tag) — cards now, not `.alert`s. Each keeps its draft in
            // LOCAL @State inside ModalPromptCard.
            .modifier(NamePromptModals())
            // Confirms + errors raised from views that can't present (sidebar
            // rows, tiles, other modals' content). LAST in the chain on
            // purpose: attached outermost, it draws ABOVE any card that raised
            // it — a delete confirmation from inside Duplicates has to sit on
            // top of Duplicates, not behind it.
            .museModal(isPresented: Binding(
                get: { appState.alertRequest != nil },
                set: { if !$0 { appState.alertRequest = nil } }),
                       width: ModalMessageCardWidth.standard,
                       palette: appState.moodPalette) {
                if let alert = appState.alertRequest {
                    ModalMessageCard(alert: alert) { appState.alertRequest = nil }
                        .id(alert.id)
                }
            }
            // Announcements (DECIDED #28). Presented at the shell like every
            // other modal, and mirrored into AppState.announcementPresented so
            // the grid's key catcher and the Escape resolver treat it as one.
            .museModal(isPresented: Binding(
                get: { announcementStore.pending != nil },
                set: { if !$0, let a = announcementStore.pending { announcementStore.dismiss(a.id) } }),
                       width: ModalMessageCardWidth.standard,
                       palette: appState.moodPalette) {
                if let a = announcementStore.pending {
                    AnnouncementCard(announcement: a) { announcementStore.dismiss(a.id) }
                        .id(a.id)
                }
            }
            .onChange(of: announcementStore.pending) { _, pending in
                appState.announcementPresented = pending != nil
            }
            // Transparent title bar so the sidebar card flows continuously up
            // to the top and curves with the window corner (Lineform-style).
            .toolbarBackground(.hidden, for: .windowToolbar)
            // No window title — the toolbar is a bare control strip.
            .navigationTitle("")
            // The viewer covers everything (prototype) — no toolbar above it.
            // The toolbar stays MOUNTED the whole time and is cross-faded at the
            // AppKit layer (ToolbarFade): SwiftUI's `.toolbar(.hidden)` tears the
            // native NSToolbar down and re-materializes it on close, which is
            // what caused BOTH the search-bar shadow "flash" (2026-06-18,
            // then accepted as inherent) and the late, all-at-once pop-in of the
            // nav icons after the close flight. An alpha fade re-materializes
            // nothing, so neither artifact can occur — and since the toolbar
            // never leaves the layout, the overlay size is stable for the whole
            // flight (the old same-transaction-hide constraint is moot).
            // Fade-in is driven by viewerDismissing, which is set in ONE place —
            // startClose() — that both close paths funnel through: the X button
            // calls it directly, Escape via the viewerClosing onChange. The
            // Escape handler must NOT set viewerDismissing itself; a second,
            // separate write there toggled the toolbar mid-transaction and
            // regressed Escape into needing two presses (see the 2026-06-18 fix).
            .onChange(of: appState.selectedFile != nil) { _, viewerOpen in
                if viewerOpen {
                    ToolbarFade.hide()
                } else {
                    // Non-hero viewers (video/PDF/text…) close by clearing
                    // selectedFile directly, without a dismiss flight. Also a
                    // no-op safety net after hero closes (already shown).
                    ToolbarFade.show()
                }
            }
            .onChange(of: appState.viewerDismissing) { _, dismissing in
                // Hero close: bring the nav back WITH the return flight.
                if dismissing { ToolbarFade.show() }
            }
            // Full-screen hides the toolbar via SwiftUI (ToolbarFade's AppKit
            // fade can't reach the OS-relocated full-screen toolbar). Constant
            // `.automatic` in windowed mode (never toggles there); flips to
            // `.hidden` only when a viewer is open in full-screen. The full-screen
            // return has a small rebuild delay — accepted tradeoff.
            .toolbar(appState.selectedFile != nil && isFullScreen ? .hidden : .automatic,
                     for: .windowToolbar)
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didEnterFullScreenNotification)) { _ in
                isFullScreen = true
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didExitFullScreenNotification)) { _ in
                isFullScreen = false
            }
            .onAppear {
                if let win = NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil }) {
                    isFullScreen = win.styleMask.contains(.fullScreen)
                }
            }
        }

        // Window-level overlays: the hero viewer spans the whole window —
        // sidebar and toolbar included — exactly like the prototype.
        if let selected = appState.selectedFile {
            // Hero (image) viewers mount instantly: the prototype's stage is
            // opaque from the first frame — only its backdrop fades in.
            // Fading the whole subtree made the flight semi-transparent.
            ViewerRouter(file: selected)
                .transition(selected.kind == .image || selected.kind == .raw
                            || selected.kind == .psd ? .identity : .opacity)
        }
        GridToastHost(deletion: appState.deletion)
            .zIndex(60)
        }
        .animation(.easeInOut(duration: 0.18), value: appState.selectedFile?.id)
        .background(
            Button(action: {
                // Escape backs out of the current focused context, innermost-first
                // (EscapeResolver). Any open viewer wins outright, so the back-out
                // chain (collection → Collections page → grid) can never interleave
                // with the delicate hero close. Each case maps onto the SAME call
                // the visible back button makes, so behavior stays in parity.
                let selected = appState.selectedFile
                let isHero = selected.map {
                    $0.kind == .image || $0.kind == .raw || $0.kind == .psd
                } ?? false
                // "Search present" mirrors selectFolder's teardown check so a
                // typed-but-not-yet-fired query (debounce in flight) is peeled
                // too — the field text is LOCAL @State now (searchQuery commits
                // only when a run fires), so check BOTH.
                let searchPresent = EscapeResolver.searchPresent(
                    isSearchActive: appState.isSearchActive,
                    queryIsEmpty: appState.searchQuery.isEmpty && searchText.isEmpty)
                switch EscapeResolver.action(
                    modalPresented: appState.modalPresented,
                    hasSelectedFile: selected != nil,
                    selectedFileIsHero: isHero,
                    searchActive: searchPresent,
                    tagsActive: !appState.activeTagLabels.isEmpty,
                    insideCollection: appState.activeCollectionID != nil,
                    showingCollectionsPage: appState.showingCollections
                ) {
                case .closeHero:
                    // Hero viewer: run the return flight instead of popping.
                    // Fire the SINGLE trigger (viewerClosing) and let startClose()
                    // — run via HeroImageViewer's viewerClosing onChange — own the
                    // whole close, including bringing the nav back (it sets
                    // viewerDismissing itself). This is exactly what the X button
                    // does. A previous pass also set viewerDismissing here, up
                    // front, to shave the onChange hop's "beat"; that extra,
                    // separate @Published write (toolbar toggles mid-transaction)
                    // regressed Escape into needing TWO presses — the nav returned
                    // but the close didn't complete. Route everything through the
                    // one flag so both paths are truly identical.
                    appState.viewerClosing = true
                case .closeViewer:
                    // Match the in-viewer ✕/backdrop close (and the hero-image
                    // Esc): leave nothing selected on the grid behind.
                    appState.clearSelection()
                    appState.selectedFile = nil
                case .clearSearch:
                    // Peel the search first (it left any collection intact), so
                    // this returns to the collection's members or the folder grid.
                    // Clear the LOCAL field + pending debounce explicitly — with
                    // an uncommitted query, searchQuery is already "" so the
                    // searchQuery→searchText sync won't fire.
                    searchDebounce?.cancel()
                    searchText = ""
                    appState.clearSearch()
                case .clearTags:
                    // Clear the whole tag set in one press (not one tag at a time).
                    appState.setActiveTag(nil)
                case .exitCollection:
                    // Same as the in-collection header BackArrowButton.
                    appState.setActiveCollection(nil)
                case .exitCollectionsPage:
                    // Same as the Collections-page back arrow.
                    appState.toggleCollectionsPage()
                case .dismissModal:
                    dismissTopModal()
                case .none:
                    break
                }
            }) { EmptyView() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        )
        // Preload the tag-label list for the selection menu, and keep it fresh
        // as tags change.
        .task { appState.refreshTagLabels() }
        .onChange(of: appState.tagsVersion) { _, _ in appState.refreshTagLabels() }
        // Selection belongs to the grid: entering or leaving search clears it,
        // so actions never operate on images the search has hidden.
        .onChange(of: appState.isSearchActive) { _, _ in appState.clearSelection() }
        // Speak the running selection count for VoiceOver users as it changes.
        .onChange(of: appState.selectedFiles.count) { _, count in
            guard count > 0 else { return }
            let message = count == 1 ? "1 image selected" : "\(count) images selected"
            NSAccessibility.post(
                element: NSApp.mainWindow as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ])
        }
        .onChange(of: workInput) { _, new in advanceProgress(new) }
        // The phases go idle in GAPS, and an idle phase publishes nothing — so
        // `onChange` alone can't notice that the grace window has elapsed. This
        // tick is what actually ends a finished run.
        //
        // Bound to `isActive` so it exists ONLY while the pill is up. As a
        // `Timer.publish(...).autoconnect()` it woke the main runloop three
        // times a second for the entire life of the app, idle or not — which is
        // exactly the sort of background hum this app is supposed to not have.
        // A run can only START from the `onChange` above, so nothing is missed
        // by not ticking while idle.
        .task(id: workProgress.isActive) {
            guard workProgress.isActive else { return }
            while !Task.isCancelled && workProgress.isActive {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                advanceProgress(workInput)
            }
        }
        .preferredColorScheme(appState.moodPalette.scheme)
    }

    // MARK: - Detail core

    /// The grid/Collections stage the detail toolbar hangs off. Extracted so the
    /// body can apply `.toolbar` twice (spaced on macOS 26, plain earlier) under
    /// an `if #available` that lives OUTSIDE the toolbar builder — see the
    /// comment at the call site.
    private var detailCore: some View {
        detailStage
            // The pill belongs to the GRID, not the window. As an overlay on
            // the whole NavigationSplitView it spanned sidebar + grid, so on a
            // narrow window it slid over the sidebar and collided with its
            // Folder button. Scoping it here fixed that; seating it
            // bottom-LEADING — mirroring the zoom control's bottom-trailing
            // seat, same 16pt insets — fixed the rest, since centred it still
            // drifted into that control as the window narrowed. Growing from
            // opposite edges, the two can only meet on a window narrower than
            // both put together.
            .overlay(alignment: .bottomLeading) {
                // ONE pill for every background phase. This used to be a
                // four-way chain (Analyzing / Organizing / Indexing / Loading
                // images), each with its own counter — after the 2026-07-28 perf
                // work the phases got fast enough that it switched labels faster
                // than a human can read AND restarted the count at zero on each
                // switch. A user only needs to know progress is happening.
                if workProgress.isActive {
                    statusPill(label: "Preparing your files…",
                               progress: workProgress.fraction,
                               percent: workProgress.percent)
                }
            }
    }

    private var detailStage: some View {
        ZStack {
            HStack(spacing: 0) {
                // ZStack (not VStack) so the page⇄grid swap CROSS-fades in
                // place — both occupy the same slot during the transition
                // instead of one collapsing and the other growing from the
                // top (the abrupt "top-down" reload).
                ZStack {
                    if isCollectionsPage {
                        // Dedicated Collections page — no tag chips here.
                        CollectionsPage()
                            .transition(Self.pageReveal)
                    } else {
                        // Chips stay pinned — on the main grid AND inside a
                        // collection (so tags filter within a collection).
                        // The collection header lives inside the grid's
                        // scroll view and scrolls with it. Hidden only
                        // during search and on the Collections page.
                        VStack(spacing: 0) {
                            // Chips stay mounted during search too — tags now
                            // narrow within the search result set (AND).
                            TagChipsRow()
                            GridView()
                        }
                        .transition(Self.pageReveal)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(appState.moodPalette.background)
                .animation(.easeInOut(duration: 0.35), value: appState.moodPalette)
                // Search enter/exit still crossfades via this ambient animation.
                .animation(.easeInOut(duration: AppState.navTransition), value: appState.isSearchActive)
                // NOTE: deliberately NO ambient animation on isCollectionsPage or
                // activeCollectionID. Those transitions are driven explicitly by
                // withAnimation inside toggleCollectionsPage / setActiveCollection /
                // setActiveTag, so a FOLDER switch can tear the old tag/collection
                // view down INSTANTLY (animated: false) — it vanishes in one frame
                // instead of animating away in visible steps before the new folder
                // fades in.
            }
        }
    }

    // MARK: - Toolbar content
    //
    // LAYOUT: all controls left-aligned (`.navigation`); search alone at the far
    // RIGHT (`.primaryAction`). Each control is its OWN pill (like the folder
    // toggle). On macOS 26 (Tahoe, liquid glass) adjacent toolbar items MERGE into
    // one shared glass capsule; a fixed `ToolbarSpacer` between each forces them
    // apart. `ToolbarSpacer` is macOS-26-only, so the body applies the SPACED
    // variant on 26 and the PLAIN variant on Sonoma/Sequoia (which never merge —
    // each item already renders individually). Each button is defined ONCE below
    // and composed twice, so there's zero logic duplication; the spaced list is
    // split in two because `@ToolbarContentBuilder.buildBlock` tops out at 10
    // elements (9 items + 8 spacers = 17). These lists must stay FLAT — an
    // `if #available` inside a toolbar builder erases the structure the spacers
    // need and they get silently ignored (verified live, twice).
    //
    // Per-item `.disabled` differs: sort/direction/Collections/Layout die during
    // search; the funnel stays live during search but dies on the Collections CARD
    // page; subfolders dies during search AND in the Collections world; mood/info
    // are always live.

    // The SPACED variant lives entirely in the `.automatic` (trailing) section:
    // ToolbarSpacer group-breaks are honored there but silently IGNORED between
    // `.navigation`-placed items (verified live — three `.navigation` shapes all
    // rendered fused). Fixed spacers split each control into its own pill; the
    // FLEXIBLE spacer expands between the controls and the search field, pinning
    // the strip left and the search right within the section.
    @available(macOS 26.0, *)
    @ToolbarContentBuilder
    private var spacedLeadingA: some ToolbarContent {
        // Sort · direction (newest-first) · filter share ONE capsule — no spacers
        // between them (adjacent unspaced items merge by default). The spacer AFTER
        // filter closes the group; tag + subfolders each get their own pill.
        sortItem(.automatic)
        directionItem(.automatic)
        filterItem(.automatic)
        ToolbarSpacer(.fixed)
        tagItem(.automatic)
        ToolbarSpacer(.fixed)
        subfoldersItem(.automatic)
        ToolbarSpacer(.fixed)
    }

    @available(macOS 26.0, *)
    @ToolbarContentBuilder
    private var spacedLeadingB: some ToolbarContent {
        // Collections · Image Layout · Manage Drive Links share ONE capsule — no
        // spacers between them (none is a chevron Menu, so they merge cleanly).
        // The spacer AFTER manage-drive-links closes the group; Background (mood)
        // and info each stay their own pill.
        collectionsItem(.automatic)
        layoutItem(.automatic)
        manageDriveLinksItem(.automatic)
        ToolbarSpacer(.fixed)
        moodItem(.automatic)
        ToolbarSpacer(.fixed)
        // About + Settings share ONE capsule (no spacer between them): they're
        // the two "about this app" controls and read as a pair. Settings is here
        // as well as under ⌘, so it doesn't live only in the Apple menu.
        infoItem(.automatic)
        settingsItem(.automatic)
        ToolbarSpacer(.flexible)
    }

    // Sonoma/Sequoia don't merge items into a shared capsule, so these render
    // individually regardless — but keep the sort · direction · filter ORDER
    // consistent with the Tahoe grouping above.
    //
    // Split in two only because `@ToolbarContentBuilder.buildBlock` tops out at
    // 10 elements and the list is now 11. The two halves are applied adjacently
    // at the call site, so the rendered order is identical to one flat list.
    @ToolbarContentBuilder
    private var plainLeadingA: some ToolbarContent {
        sortItem(.navigation)
        directionItem(.navigation)
        filterItem(.navigation)
        tagItem(.navigation)
        subfoldersItem(.navigation)
        collectionsItem(.navigation)
    }

    @ToolbarContentBuilder
    private var plainLeadingB: some ToolbarContent {
        layoutItem(.navigation)
        manageDriveLinksItem(.navigation)
        moodItem(.navigation)
        infoItem(.navigation)
        settingsItem(.navigation)
    }

    // Individual items — each renders as its own pill.

    /// A toolbar button's label: the mood-tinted glyph, PLUS a text title that
    /// the bar itself never draws.
    ///
    /// `.labelStyle(.iconOnly)` keeps the toolbar icon-only, but the Label still
    /// carries its title — which is what the `»` overflow menu shows when the
    /// window narrows. With a bare `Image` the overflow was a column of
    /// unlabelled glyphs; with this it reads as a normal menu.
    private func toolbarGlyph(_ systemImage: String,
                              _ title: LocalizedStringKey,
                              selected: Bool = false) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .moodToolbarIcon(appState.moodPalette, selected: selected)
        }
        .labelStyle(.iconOnly)
    }

    @ToolbarContentBuilder
    private func sortItem(_ placement: ToolbarItemPlacement) -> some ToolbarContent {
        ToolbarItem(placement: placement) {
            sortMenu.disabled(appState.isSearchActive)
        }
    }

    @ToolbarContentBuilder
    private func filterItem(_ placement: ToolbarItemPlacement) -> some ToolbarContent {
        ToolbarItem(placement: placement) {
            filterMenu.disabled(isCollectionsPage)
        }
    }

    @ToolbarContentBuilder
    private func directionItem(_ placement: ToolbarItemPlacement) -> some ToolbarContent {
        // Flip the active sort mode's direction (newest↔oldest, A↔Z, …).
        ToolbarItem(placement: placement) {
            sortDirectionMenu.disabled(appState.isSearchActive)
        }
    }

    @ToolbarContentBuilder
    private func tagItem(_ placement: ToolbarItemPlacement) -> some ToolbarContent {
        // Tag-chip sort order (Most Used / A→Z).
        ToolbarItem(placement: placement) {
            tagSortMenu.disabled(isCollectionsPage)
        }
    }

    @ToolbarContentBuilder
    private func subfoldersItem(_ placement: ToolbarItemPlacement) -> some ToolbarContent {
        ToolbarItem(placement: placement) {
            // The binding routes the click through toggleSubfolders() — the
            // single owner of the flip + its side effects (narrowing-direction
            // selection clear, reload). Binding straight to $showSubfolders
            // with an .onChange calling toggleSubfolders() double-drove the
            // value: the Toggle wrote it, then the handler flipped it AGAIN,
            // re-firing onChange — extra reloads, and the transient
            // opposite-state pass cleared the selection on the widening
            // direction too, against the documented rule.
            Toggle(isOn: Binding(get: { appState.showSubfolders },
                                 set: { _ in appState.toggleSubfolders() })) {
                toolbarGlyph("rectangle.stack", "Subfolders",
                             selected: appState.showSubfolders)
            }
            .help(appState.showSubfolders
                  ? "Hide files inside subfolders"
                  : "Show files inside subfolders")
            // Icon-only toggle: give VoiceOver a stable name (its on/off state is
            // announced by the toggle itself).
            .accessibilityLabel("Show files in subfolders")
            .disabled(appState.isSearchActive || inCollectionsContext)
        }
    }

    @ToolbarContentBuilder
    private func collectionsItem(_ placement: ToolbarItemPlacement) -> some ToolbarContent {
        // No selected/blue state: it's navigation with its own back button.
        ToolbarItem(placement: placement) {
            Button {
                appState.toggleCollectionsPage()
            } label: {
                toolbarGlyph("rectangle.on.rectangle.angled", "Collections")
            }
            .help("Collections")
            .accessibilityLabel("Collections")
            .disabled(appState.isSearchActive)
        }
    }

    @ToolbarContentBuilder
    private func layoutItem(_ placement: ToolbarItemPlacement) -> some ToolbarContent {
        ToolbarItem(placement: placement) {
            Button {
                appState.imageLayoutShown = true
            } label: {
                toolbarGlyph("square.grid.2x2", "Image Layout")
            }
            .help("Image Layout")
            // Icon-only button: give VoiceOver an explicit name (the SF Symbol's
            // derived label reads "square grid 2x2").
            .accessibilityLabel("Image Layout")
            .disabled(appState.isSearchActive)
        }
    }

    @ToolbarContentBuilder
    private func manageDriveLinksItem(_ placement: ToolbarItemPlacement) -> some ToolbarContent {
        // Opens the global Drive share list (the same sheet as the View-menu
        // "Manage Drive Shares…"). Uses the "link" symbol to read as a
        // share-link affordance. Greyed out during search, like its
        // capsule-mates Collections and Image Layout.
        ToolbarItem(placement: placement) {
            Button {
                appState.driveSharesShown = true
            } label: {
                toolbarGlyph("link", "Manage Drive Shares")
            }
            .help("Manage Drive Shares")
            .accessibilityLabel("Manage Drive Shares")
            .disabled(appState.isSearchActive)
        }
    }

    @ToolbarContentBuilder
    private func moodItem(_ placement: ToolbarItemPlacement) -> some ToolbarContent {
        ToolbarItem(placement: placement) {
            moodMenu
        }
    }

    @ToolbarContentBuilder
    private func infoItem(_ placement: ToolbarItemPlacement) -> some ToolbarContent {
        ToolbarItem(placement: placement) {
            Button {
                appState.infoShown = true
            } label: {
                toolbarGlyph("info.circle", "About Muse")
            }
            .help("About Muse — how indexing, analysis, collections, and tags work")
            .accessibilityLabel("About Muse")
        }
    }

    /// Opens the in-app Settings card. Deliberately the SAME action as the ⌘,
    /// menu command (`AppState.settingsShown`), so there's one presentation path
    /// — this is a second door to it, not a second implementation.
    @ToolbarContentBuilder
    private func settingsItem(_ placement: ToolbarItemPlacement) -> some ToolbarContent {
        ToolbarItem(placement: placement) {
            Button {
                appState.settingsShown = true
            } label: {
                toolbarGlyph("gearshape", "Settings")
            }
            .help("Settings")
            .accessibilityLabel("Settings")
        }
    }

    // MARK: - Search wiring (native `.searchable`)

    /// Field text changed. Debounce a run (250ms) or clear on empty. The text
    /// is NOT pushed into `AppState.searchQuery` per keystroke — that's a
    /// @Published on the monolithic AppState, so each key re-evaluated the
    /// whole shell (the exact cost the local-@State field exists to avoid).
    /// The committed-query publish happens in `runSearchNow` when the
    /// debounce fires / Return commits.
    private func handleSearchTextChange(_ newValue: String) {
        // Kill any pending run FIRST — a backspace-to-empty must not let a
        // stale keystroke's debounce fire after the field cleared.
        searchDebounce?.cancel()
        // Matches the committed query → this is the programmatic-injection
        // echo (the searchQuery → searchText sync below) — nothing to run.
        guard newValue != appState.searchQuery else { return }
        if newValue.isEmpty {
            appState.clearSearch()
        } else {
            searchDebounce = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !Task.isCancelled { runSearchNow(newValue) }
            }
        }
    }

    /// Scope picker (All / This Folder) changed. Re-run an active, non-empty
    /// search immediately under the new scope; an idle search just stores it.
    private func setSearchScope(_ scope: SearchFolderScope) {
        let allFolders = (scope == .all)
        guard appState.searchAllFolders != allFolders else { return }
        appState.searchAllFolders = allFolders
        // Re-run the FIELD text, not the committed searchQuery: with the
        // deferred commit, a scope toggle mid-debounce would otherwise re-run
        // the stale committed query AND cancel the newer typed one.
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if appState.isSearchActive, !q.isEmpty { runSearchNow(q) }
    }

    private func runSearchNow(_ query: String) {
        searchDebounce?.cancel()
        // Commit the query to AppState here (once per run, not per keystroke).
        if appState.searchQuery != query { appState.searchQuery = query }
        Task { await appState.runSearch(query) }
    }

    @ViewBuilder
    private var sortMenu: some View {
        // On the Collections page the menu sorts the cards (collection modes
        // only); elsewhere it sorts the grid (all modes). Mirrors the
        // `isCollectionsPage` ternary in sortDirectionMenu + the help below.
        let cases = isCollectionsPage ? SortMode.collectionCases : SortMode.allCases
        let selection = Binding(
            get: { isCollectionsPage ? appState.collectionSortMode : appState.sortMode },
            set: { mode in
                if isCollectionsPage {
                    appState.collectionSortMode = mode
                } else {
                    appState.sortMode = mode
                    appState.resort()
                }
            }
        )
        Menu {
            // Picker gives native menu checkmarks (the empty-systemImage Label
            // hack logged "no symbol named ''" console noise). One flat list —
            // on the grid, Color and Shape simply use Analyze data when it
            // exists, no Standard/Smart ceremony.
            Picker("Sort", selection: selection) {
                ForEach(cases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            toolbarGlyph("arrow.up.and.down.text.horizontal", "Sort")
        }
        // Hide the dropdown chevron: with it, macOS 26 renders the Menu as its
        // OWN isolated glass pill and it won't merge with the adjacent
        // direction/filter controls into the "sorting" cluster.
        .menuIndicator(.hidden)
        .help("Sort: \(isCollectionsPage ? appState.collectionSortMode.displayName : appState.sortMode.displayName)")
        .accessibilityLabel("Sort")
    }

    /// Orders the tag chips above the grid: Most Used (count) or A→Z.
    private var tagSortMenu: some View {
        Menu {
            Picker("Tag order", selection: Binding(
                get: { appState.tagSortMode },
                set: { appState.tagSortMode = $0 }
            )) {
                ForEach(TagSortMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            toolbarGlyph("tag", "Tag Order")
        }
        .help("Tag order: \(appState.tagSortMode.label)")
        .accessibilityLabel("Tag order")
    }

    /// Sort direction. A bare toggle button gave no clue what a click would do,
    /// so this is a Menu listing the two directions SPELLED OUT for the active
    /// mode ("Newest first" / "Oldest first", "Largest first" / "Smallest
    /// first", …) via `SortMode.directionLabel`. The toolbar glyph still shows
    /// the current state at a glance: up for ascending, down for descending.
    ///
    /// On the Collections page it drives the collections sort; elsewhere the
    /// grid sort. Both write through their `toggle…` method rather than setting
    /// `sortReversed` directly — the grid's setter also runs `resort()`, so a
    /// direct write would change the arrow without reordering anything.
    private var sortDirectionMenu: some View {
        let ascending = isCollectionsPage ? appState.collectionSortAscending : appState.sortAscending
        let mode = isCollectionsPage ? appState.collectionSortMode : appState.sortMode
        return Menu {
            Picker("Sort direction", selection: Binding(
                get: { ascending },
                set: { wanted in
                    // Re-picking the active direction is a no-op; only a real
                    // change flips (and re-sorts).
                    guard wanted != ascending else { return }
                    if isCollectionsPage { appState.toggleCollectionSortDirection() }
                    else { appState.toggleSortDirection() }
                }
            )) {
                Label(mode.directionLabel(ascending: false), systemImage: "arrow.down")
                    .tag(false)
                Label(mode.directionLabel(ascending: true), systemImage: "arrow.up")
                    .tag(true)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            toolbarGlyph(ascending ? "arrow.up" : "arrow.down", "Sort Direction")
        }
        // Same reason as the sort menu beside it: with the dropdown chevron
        // visible, macOS 26 renders this as its OWN isolated glass pill and it
        // stops merging with sort + filter into the one "sorting" capsule.
        .menuIndicator(.hidden)
        .help(mode.directionLabel(ascending: ascending))
        .accessibilityLabel(String(localized: "Sort direction: \(mode.directionLabel(ascending: ascending))"))
    }

    @ViewBuilder
    private var filterMenu: some View {
        // Native toolbar Toggle in `.button` style: when "on" it gets the
        // standard selected fill (solid accent, white icon). We drive "on" from
        // (popover open) OR (a filter is active) so the engaged blue persists
        // while a filter is set even with the popover closed — the always-visible
        // reminder. The setter ignores the incoming value and only toggles the
        // popover, so a click always opens/closes it (never silently clears the
        // filter). NOT disabled during search: the funnel narrows results too.
        Toggle(isOn: Binding(
            get: { filterPopoverShown || appState.gridFilter.isActive },
            set: { _ in filterPopoverShown.toggle() }
        )) {
            toolbarGlyph("line.3.horizontal.decrease.circle", "Filter",
                         selected: filterPopoverShown || appState.gridFilter.isActive)
        }
        .toggleStyle(.button)
        .help(appState.gridFilter.isActive ? String(localized: "Filter (active)") : String(localized: "Filter"))
        .accessibilityLabel("Filter")
        // The toggle's "on" state doubles for popover-open, so announce the
        // actual filter state separately (keeps the stable name "Filter").
        .accessibilityValue(appState.gridFilter.isActive ? String(localized: "Active") : String(localized: "Off"))
        .popover(isPresented: $filterPopoverShown, arrowEdge: .bottom) {
            GridFilterPopover()
                .environmentObject(appState)
        }
    }

    @ViewBuilder
    private var moodMenu: some View {
        // Native toolbar Toggle: macOS gives it the standard icon size, the
        // round hover state, and — while "on" (popover open) — the native
        // selected fill (solid accent, white icon), identical to every other
        // toolbar button's behavior. No custom chrome.
        Toggle(isOn: $moodPickerShown) {
            // `selected:` is what swaps the glyph to white against the toggle's
            // solid accent fill, the same as Collections and Filter. Dropping it
            // left a mood-tinted glyph sitting on blue.
            toolbarGlyph("paintpalette", "Background", selected: moodPickerShown)
        }
        .toggleStyle(.button)
        .help("Background: \(appState.mood.displayName)")
        .accessibilityLabel("Background")
        .popover(isPresented: $moodPickerShown, arrowEdge: .bottom) {
            MoodPickerView()
                .environmentObject(appState)
        }
    }

    /// Feed one reading to the unified bar, and schedule the completion hold
    /// when a run genuinely ends.
    private func advanceProgress(_ input: WorkProgress.Input) {
        withAnimation(.easeOut(duration: 0.2)) { workProgress.update(input) }
        // A run that resumed (or a fresh one) clears any stale hold claim, so
        // the guard below can't be left latched by a hold that was superseded.
        // Today a finish needs 1.5s of idle and the hold lasts 0.45s, so they
        // can't overlap — but that is an accident of two constants, and if it
        // ever stopped being true the bar would stick at 100% forever.
        if !workProgress.isFinishing { finishHoldScheduled = false }
        // Let the bar visibly REACH 100% before the pill goes away. Without
        // the hold it vanished at whatever the last active phase reached
        // (typically the low 90s), which reads as a stall rather than
        // completion.
        // Schedule the hold ONCE. `isFinishing` stays true for its whole
        // duration, and the tick above re-enters every 0.3s, so an unguarded
        // schedule queued a fresh reset on each tick (harmless — `reset()` is
        // guarded — but pointless churn).
        guard workProgress.isFinishing, !finishHoldScheduled else { return }
        finishHoldScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.easeOut(duration: 0.25)) { workProgress.reset() }
            finishHoldScheduled = false
        }
    }

    /// Live snapshot of every background phase, fed to the unified pill.
    /// Equatable, so `.onChange` only fires on a real change.
    private var workInput: WorkProgress.Input {
        WorkProgress.Input(
            indexFraction: Double(indexProgress.completed) / Double(max(indexProgress.total, 1)),
            indexActive: indexProgress.isActive,
            analyzeFraction: analyzePipeline.progress,
            analyzeActive: analyzePipeline.isRunning,
            organizing: collectionsEngine.isClustering)
    }

    /// One shared pill for every phase — same glass as the grid's column
    /// slider: ultra-thin material capsule, hairline outline, same height,
    /// same 16pt bottom seat.
    private func statusPill(label: LocalizedStringKey, progress: Double,
                            percent: Int) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: min(max(progress, 0), 1))
                .progressViewStyle(.linear)
                .frame(width: 120)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            // A long pass over a big folder can sit at a similar-looking bar
            // for a while; the number is what tells you it is still moving.
            // Monospaced digits so it doesn't jitter as it counts.
            // Same .secondary as the label beside it — on .tertiary it read as
            // disabled next to live text.
            Text(verbatim: "\(percent)%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        // Hug the content — the pills now show short, stable counts (no
        // filenames), so the capsule stays compact and centered instead of
        // stretching across the window.
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 20)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .padding(.leading, 16)
        .padding(.bottom, 16)
        .transition(.opacity)
    }

    // MARK: - Suggestion sources for the Add Tag / New Collection cards

    /// Every tag label in the library, most-used first, for the Add Tag card's
    /// autocomplete. Read from the chip cache AppState already maintains (it's
    /// refreshed on every tagsVersion bump), so opening the card costs no query.
    ///
    /// Rating glyphs are dropped by `TagSuggest.rank` itself, so this doesn't
    /// have to remember to — attaching one here would give a file two ratings.
    private var tagSuggestCandidates: [TagSuggest.Candidate] {
        let all = appState.allTagLabels
        let n = all.count
        // allTagLabels arrives already ordered; encode that order as the count
        // so an empty query preserves it (no second query just for counts).
        return all.enumerated().map { i, label in
            TagSuggest.Candidate(label: label, count: n - i)
        }
    }

    /// Existing MANUAL collection names, so "Name Collection" can show what's
    /// already taken and route a matching name into that collection instead of
    /// creating a twin. Smart collections are excluded: their membership is
    /// rule-driven, so hand-adding files to one wouldn't stick.
    /// Tags carried by photos that LOOK like the one being tagged. Loaded when
    /// the Add Tag card opens; empty until it lands (the card reserves the row's
    /// height, so a late arrival doesn't resize it) and empty forever for an
    /// unanalyzed photo, which is fine — the field still inline-completes.
    private func loadSimilarTags(for request: AddTagRequest) async {
        similarTags = []
        // The CLICKED file, not `urls.first` — a multi-selection has no single
        // "this photo", and the URL list is unordered.
        let url = request.source
        // Don't offer a tag the file already carries — re-adding is a harmless
        // no-op, but seeing it in the row reads as the app not knowing.
        let existing = Set(await TagStore.shared.tags(for: url).map(\.label))
        let found = await SimilarTagSuggestions.candidates(
            for: url, excluding: existing,
            limit: SuggestingNameCard.rowCount)
        // The card may have been dismissed or re-targeted while this ran.
        guard appState.addTagRequest?.id == request.id else { return }
        similarTags = found
    }

    private var collectionSuggestCandidates: [TagSuggest.Candidate] {
        collectionsEngine.collections
            .filter { $0.collection.smart_rules == nil }
            .map { TagSuggest.Candidate(id: $0.collection.id,
                                        label: $0.collection.name,
                                        count: $0.aliveCount) }
    }
}

/// The tag confirmations — Delete Tag, Delete All Tags, Regenerate Tags.
///
/// Raised HERE rather than in `TagChipsRow`, which owns the chips that trigger
/// two of them: the row is absent on the Collections page, and the menu bar can
/// set these request flags from there. A flag set with no live consumer would
/// stick — the next request would be the same value, fire no `.onChange`, and
/// the command would be dead for the rest of the session. The shell is always
/// mounted, so the request is always consumed.
private struct TagCommandAlerts: ViewModifier {
    @EnvironmentObject private var appState: AppState

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.tagDeleteRequest) { _, label in
                guard let label else { return }
                appState.tagDeleteRequest = nil
                appState.alertRequest = .confirm(
                    title: String(localized: "Delete “\(label)”?"),
                    message: String(localized: "Removes “\(label)” from the images in this view. Other folders keep their tags. Your images stay on disk."),
                    confirmTitle: String(localized: "Delete"),
                    onConfirm: { appState.deleteTagInView(label) })
            }
            .onChange(of: appState.deleteAllTagsRequest) { _, requested in
                guard requested else { return }
                appState.deleteAllTagsRequest = false
                appState.alertRequest = .confirm(
                    title: String(localized: "Delete all tags in this view?"),
                    message: String(localized: "This removes every tag on the images in this view — both automatic tags and ones you've added yourself. Tags you added by hand can't be recovered. Your images stay on disk."),
                    confirmTitle: String(localized: "Delete All"),
                    onConfirm: { appState.deleteAllTagsInView() })
            }
            .onChange(of: appState.regenerateTagsRequest) { _, requested in
                guard requested else { return }
                appState.regenerateTagsRequest = false
                appState.alertRequest = .confirm(
                    title: String(localized: "Regenerate tags in this view?"),
                    message: String(localized: "Looks for images in this view that have no tags and generates tags for them in the background. Images that already have tags are left alone. Only automatic tags are created — tags you added by hand aren't restored."),
                    confirmTitle: String(localized: "Regenerate"),
                    destructive: false,
                    onConfirm: { appState.regenerateTaglessInView() })
            }
    }
}

/// The shell's own failure messages — folder ops, backup, file rename, and a
/// partial move. Grouped into one modifier because the detail chain hit the
/// type-checker's limit; they behave exactly as if applied inline.
private struct ShellErrorModals: ViewModifier {
    @EnvironmentObject private var appState: AppState

    func body(content: Content) -> some View {
        content
            // The shell's own error messages — folder ops, backup, rename.
            // Cards, not `.alert`s (see ModalMessageCard), and presented in the
            // detail column like every other modal so failures don't read as a
            // different, app-level layer.
            .museAlert(isPresented: Binding(get: { !appState.moveFailureNames.isEmpty },
                                            set: { if !$0 { appState.moveFailureNames = [] } }),
                       palette: appState.moodPalette,
                       title: String(localized: "Couldn’t move some files"),
                       message: appState.moveFailureNames.joined(separator: "\n"))
            .museAlert(isPresented: Binding(get: { appState.folderOpError != nil },
                                            set: { if !$0 { appState.folderOpError = nil } }),
                       palette: appState.moodPalette,
                       title: String(localized: "Folder"),
                       message: appState.folderOpError ?? "")
            .museAlert(isPresented: Binding(get: { appState.backupError != nil },
                                            set: { if !$0 { appState.backupError = nil } }),
                       palette: appState.moodPalette,
                       title: String(localized: "Backup"),
                       message: appState.backupError ?? "")
            .museAlert(isPresented: Binding(get: { appState.fileRenameError != nil },
                                            set: { if !$0 { appState.fileRenameError = nil } }),
                       palette: appState.moodPalette,
                       title: String(localized: "Rename File"),
                       message: appState.fileRenameError ?? "")
    }
}

/// The five name prompts — rename collection / file / folder / tag, and new
/// subfolder. All were `.alert`s with a TextField; they're `ModalPromptCard`s
/// now (see ModalMessageCard for why system alerts left).
///
/// The draft still lives in LOCAL `@State` — inside the card, not here — so
/// typing re-evaluates only the field and not the whole shell (binding a
/// TextField to a `@Published` on AppState made typing visibly lag on slower
/// Macs). The card is built only while presented, so it seeds itself on appear
/// and the old external `draft` + `.onChange` re-seeding plumbing is gone.
private struct NamePromptModals: ViewModifier {
    @EnvironmentObject private var appState: AppState

    func body(content: Content) -> some View {
        content
            .museModal(isPresented: Binding(
                get: { appState.collectionRenameAlertRequest != nil },
                set: { if !$0 { appState.collectionRenameAlertRequest = nil } }),
                       width: ModalMessageCardWidth.standard,
                       palette: appState.moodPalette) {
                if let req = appState.collectionRenameAlertRequest {
                    ModalPromptCard(
                        title: String(localized: "Rename Collection"),
                        message: String(localized: "Renames the collection. Its images are kept."),
                        placeholder: String(localized: "Collection name"),
                        confirmTitle: String(localized: "Rename"),
                        initialText: req.currentName,
                        onCommit: { name in
                            appState.collectionRenameAlertRequest = nil
                            appState.renameCollection(id: req.id, to: name)
                        },
                        onCancel: { appState.collectionRenameAlertRequest = nil })
                    .id(req.id)
                }
            }
            // The field holds only the STEM; the locked extension is
            // re-appended inside AppState.renameFile.
            .museModal(isPresented: Binding(
                get: { appState.fileRenameRequest != nil },
                set: { if !$0 { appState.fileRenameRequest = nil } }),
                       width: ModalMessageCardWidth.standard,
                       palette: appState.moodPalette) {
                if let node = appState.fileRenameRequest {
                    let split = FileNameSplit.split(node.basename)
                    ModalPromptCard(
                        title: String(localized: "Rename File"),
                        message: split.ext.isEmpty
                            ? String(localized: "Renames the file.")
                            : String(localized: "The “\(split.ext)” extension is kept."),
                        placeholder: String(localized: "Name"),
                        confirmTitle: String(localized: "Rename"),
                        initialText: split.stem,
                        onCommit: { name in
                            appState.fileRenameRequest = nil
                            appState.renameFile(node, to: name)
                        },
                        onCancel: { appState.fileRenameRequest = nil })
                    .id(node.id)
                }
            }
            .museModal(isPresented: Binding(
                get: { appState.newSubfolderRequest != nil },
                set: { if !$0 { appState.newSubfolderRequest = nil } }),
                       width: ModalMessageCardWidth.standard,
                       palette: appState.moodPalette) {
                if let node = appState.newSubfolderRequest {
                    ModalPromptCard(
                        title: String(localized: "New Subfolder"),
                        message: String(localized: "Creates a new folder inside “\(node.displayName)”."),
                        placeholder: String(localized: "Folder name"),
                        confirmTitle: String(localized: "Create"),
                        onCommit: { name in
                            appState.newSubfolderRequest = nil
                            appState.createSubfolder(named: name, in: node)
                        },
                        onCancel: { appState.newSubfolderRequest = nil })
                    .id(node.id)
                }
            }
            .museModal(isPresented: Binding(
                get: { appState.folderRenameRequest != nil },
                set: { if !$0 { appState.folderRenameRequest = nil } }),
                       width: ModalMessageCardWidth.standard,
                       palette: appState.moodPalette) {
                if let node = appState.folderRenameRequest {
                    ModalPromptCard(
                        title: String(localized: "Rename Folder"),
                        message: String(localized: "Renames the folder on disk. Tags and collections are kept."),
                        placeholder: String(localized: "Folder name"),
                        confirmTitle: String(localized: "Rename"),
                        initialText: node.displayName,
                        onCommit: { name in
                            appState.folderRenameRequest = nil
                            appState.renameFolder(node, to: name)
                        },
                        onCancel: { appState.folderRenameRequest = nil })
                    .id(node.id)
                }
            }
            // Library-wide tag rename. Raised by the chip row's context menu,
            // presented here — the chip is far too narrow to size a card.
            .museModal(isPresented: Binding(
                get: { appState.tagRenameRequest != nil },
                set: { if !$0 { appState.tagRenameRequest = nil } }),
                       width: ModalMessageCardWidth.standard,
                       palette: appState.moodPalette) {
                if let label = appState.tagRenameRequest {
                    ModalPromptCard(
                        title: String(localized: "Rename Tag"),
                        message: String(localized: "Renames “\(label)” on every image in the library."),
                        placeholder: String(localized: "Tag name"),
                        confirmTitle: String(localized: "Rename"),
                        initialText: label,
                        onCommit: { appState.commitTagRename(from: label, to: $0) },
                        onCancel: { appState.tagRenameRequest = nil })
                    .id(label)
                }
            }
    }
}

private extension View {
    /// Mood-driven toolbar icon color + the SAME implicit animation the
    /// background uses (`ContentView` body, keyed on `moodPalette`). Riding
    /// `setMood`'s `withAnimation` transaction instead let the recolor reach
    /// the AppKit-hosted toolbar a beat after the background; keying the icons
    /// to the identical value/curve makes every icon flip together AND in
    /// lockstep with the background fade. `selected` keeps a toggle's native
    /// white-on-accent look (popover/subfolders "on").
    func moodToolbarIcon(_ palette: MoodPalette, selected: Bool = false) -> some View {
        modifier(MoodToolbarIcon(palette: palette, selected: selected))
    }
}

/// The explicit mood `foregroundStyle` overrides SwiftUI's automatic
/// disabled dimming, so a `.disabled` toolbar icon would stay full-color
/// (looking active though unclickable). Reading `\.isEnabled` here dims every
/// `moodToolbarIcon` control uniformly when disabled (0.4 = the house disabled
/// value, cf. MoodPickerView) — the sort cluster during search, the filter on
/// the Collections card page, etc.
private struct MoodToolbarIcon: ViewModifier {
    let palette: MoodPalette
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .foregroundStyle(selected ? Color.white : palette.iconColor)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.35), value: palette)
    }
}

/// Observes the DeleteCoordinator directly — nested ObservableObjects
/// don't republish through AppState.
private struct GridToastHost: View {
    @ObservedObject var deletion: DeleteCoordinator
    var body: some View {
        ViewerToast(toast: $deletion.toast)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
