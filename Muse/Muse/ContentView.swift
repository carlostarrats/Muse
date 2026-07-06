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
    @ObservedObject private var indexProgress = IndexProgress.shared
    @ObservedObject private var thumbProgress = ThumbProgress.shared
    @ObservedObject private var analyzePipeline = AnalyzePipeline.shared
    @ObservedObject private var collectionsEngine = CollectionsEngine.shared
    @State private var moodPickerShown = false
    @State private var infoShown = false
    @State private var imageLayoutShown = false
    @State private var filterPopoverShown = false

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
                        plainLeading
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
            // Transparent title bar so the sidebar card flows continuously up
            // to the top and curves with the window corner (Lineform-style).
            .toolbarBackground(.hidden, for: .windowToolbar)
            // No window title — the toolbar is a bare control strip.
            .navigationTitle("")
            // The viewer covers everything (prototype) — no toolbar above it.
            // Must hide in the same transaction the viewer mounts: the stage
            // computes its fit center from the overlay size, and a later hide
            // moves that center mid-flight (the image visibly arcs).
            // It returns when the close *starts* (viewerDismissing) so the nav is
            // there with the flight rather than popping in after. viewerDismissing
            // is set in ONE place — startClose() — which both close paths funnel
            // through: the X button calls it directly, Escape via the viewerClosing
            // onChange. The Escape handler must NOT set viewerDismissing itself; a
            // second, separate write there toggled the toolbar mid-transaction and
            // regressed Escape into needing two presses (see the 2026-06-18 fix).
            .toolbar(appState.selectedFile == nil || appState.viewerDismissing
                     ? .automatic : .hidden,
                     for: .windowToolbar)
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
                case .none:
                    break
                }
            }) { EmptyView() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        )
        .sheet(isPresented: $appState.duplicatesSheetVisible) {
            DuplicatesView(isPresented: $appState.duplicatesSheetVisible)
        }
        .sheet(isPresented: $infoShown) {
            InfoSheet(isPresented: $infoShown)
        }
        .sheet(isPresented: $imageLayoutShown) {
            ImageLayoutSheet(isPresented: $imageLayoutShown)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.settingsShown) {
            SettingsView(isPresented: $appState.settingsShown)
        }
        .sheet(isPresented: $appState.driveSharesShown) {
            ManageDriveSharesView()
        }
        .sheet(isPresented: $appState.reconnectShown) {
            if let model = appState.reconnectModel {
                ReconnectWizard(model: model, isPresented: $appState.reconnectShown,
                                bookmarks: appState.bookmarks)
            }
        }
        .alert("Couldn’t move some files",
               isPresented: Binding(get: { !appState.moveFailureNames.isEmpty },
                                    set: { if !$0 { appState.moveFailureNames = [] } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.moveFailureNames.joined(separator: "\n"))
        }
        // Folder management dialogs — driven by AppState requests (shared by the
        // sidebar context menu and the menu-bar Edit menu).
        .modifier(FolderNameAlerts())
        .alert("Folder", isPresented: Binding(
            get: { appState.folderOpError != nil },
            set: { if !$0 { appState.folderOpError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.folderOpError = nil }
        } message: {
            Text(appState.folderOpError ?? "")
        }
        .alert("Backup", isPresented: Binding(
            get: { appState.backupError != nil },
            set: { if !$0 { appState.backupError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.backupError = nil }
        } message: {
            Text(appState.backupError ?? "")
        }
        .modifier(NameCollectionAlert())
        .modifier(CollectionRenameAlert())
        .modifier(FileRenameAlert())
        .alert("Rename File", isPresented: Binding(
            get: { appState.fileRenameError != nil },
            set: { if !$0 { appState.fileRenameError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.fileRenameError = nil }
        } message: {
            Text(appState.fileRenameError ?? "")
        }
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
        .overlay(alignment: .bottom) {
            if analyzePipeline.isRunning {
                analyzeStatusBanner
            } else if collectionsEngine.isClustering {
                organizingBanner
            } else if indexProgress.isActive {
                indexingBanner
            } else if thumbProgress.isActive {
                thumbsBanner
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
        infoItem(.automatic)
        ToolbarSpacer(.flexible)
    }

    // Sonoma/Sequoia don't merge items into a shared capsule, so these render
    // individually regardless — but keep the sort · direction · filter ORDER
    // consistent with the Tahoe grouping above.
    @ToolbarContentBuilder
    private var plainLeading: some ToolbarContent {
        sortItem(.navigation)
        directionItem(.navigation)
        filterItem(.navigation)
        tagItem(.navigation)
        subfoldersItem(.navigation)
        collectionsItem(.navigation)
        layoutItem(.navigation)
        manageDriveLinksItem(.navigation)
        moodItem(.navigation)
        infoItem(.navigation)
    }

    // Individual items — each renders as its own pill.

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
            sortDirectionButton.disabled(appState.isSearchActive)
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
                Image(systemName: "rectangle.stack")
                    .moodToolbarIcon(appState.moodPalette,
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
                Image(systemName: "square.stack.3d.up")
                    .moodToolbarIcon(appState.moodPalette)
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
                imageLayoutShown = true
            } label: {
                Image(systemName: "square.grid.2x2")
                    .moodToolbarIcon(appState.moodPalette)
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
                Image(systemName: "link")
                    .moodToolbarIcon(appState.moodPalette)
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
                infoShown = true
            } label: {
                Image(systemName: "info.circle")
                    .moodToolbarIcon(appState.moodPalette)
            }
            .help("About Muse — how indexing, analysis, collections, and tags work")
            .accessibilityLabel("About Muse")
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
        // `isCollectionsPage` ternary in sortDirectionButton + the help below.
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
            Image(systemName: "arrow.up.and.down.text.horizontal")
                .moodToolbarIcon(appState.moodPalette)
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
            Image(systemName: "tag")
                .moodToolbarIcon(appState.moodPalette)
        }
        .help("Tag order: \(appState.tagSortMode.label)")
        .accessibilityLabel("Tag order")
    }

    /// Flips the active sort mode's direction. On the Collections page it flips
    /// the collections sort; elsewhere it flips the grid sort. The arrow points
    /// up for ascending, down for descending; the tooltip spells out what that
    /// means for the active mode (e.g. "Newest first" vs "Oldest first").
    private var sortDirectionButton: some View {
        let ascending = isCollectionsPage ? appState.collectionSortAscending : appState.sortAscending
        let mode = isCollectionsPage ? appState.collectionSortMode : appState.sortMode
        return Button {
            if isCollectionsPage { appState.toggleCollectionSortDirection() }
            else { appState.toggleSortDirection() }
        } label: {
            Image(systemName: ascending ? "arrow.up" : "arrow.down")
                .moodToolbarIcon(appState.moodPalette)
        }
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
            Image(systemName: "line.3.horizontal.decrease.circle")
                .moodToolbarIcon(appState.moodPalette,
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
            Image(systemName: "paintpalette")
                .moodToolbarIcon(appState.moodPalette, selected: moodPickerShown)
        }
        .toggleStyle(.button)
        .help("Background: \(appState.mood.displayName)")
        .accessibilityLabel("Background")
        .popover(isPresented: $moodPickerShown, arrowEdge: .bottom) {
            MoodPickerView()
                .environmentObject(appState)
        }
    }

    /// Bottom-center pill while tile thumbnails stream in for a big folder.
    private var thumbsBanner: some View {
        statusPill(label: "Loading images \(thumbProgress.completed) of \(thumbProgress.total)",
                   progress: Double(thumbProgress.completed) / Double(max(thumbProgress.total, 1)))
    }

    /// Bottom-center pill while the indexer works through a folder.
    private var indexingBanner: some View {
        statusPill(label: "Indexing \(indexProgress.completed) of \(indexProgress.total)",
                   progress: Double(indexProgress.completed) / Double(max(indexProgress.total, 1)))
    }

    /// One shared pill for every phase — same glass as the grid's column
    /// slider: ultra-thin material capsule, hairline outline, same height,
    /// same 16pt bottom seat.
    private func statusPill(label: String, progress: Double) -> some View {
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
        .padding(.bottom, 16)
        .transition(.opacity)
    }

    private var analyzeStatusBanner: some View {
        statusPill(label: analyzePipeline.total > 0
                        ? "Analyzing \(analyzePipeline.completed) of \(analyzePipeline.total)"
                        : "Analyzing…",
                   progress: analyzePipeline.progress)
    }

    /// Bottom-center pill while collections recluster after an analyze batch —
    /// closes the otherwise-invisible gap between the Analyzing pill vanishing
    /// and results appearing. Indeterminate phase, so the bar reads as
    /// "finishing up". Same capsule as every other pill.
    private var organizingBanner: some View {
        statusPill(label: "Organizing…", progress: 1)
    }

}

/// The "Name Collection" prompt's text field. Bound directly to AppState's
/// `@Published` draft, every keystroke fired `AppState.objectWillChange`, which
/// re-evaluated the whole `ContentView` body (sidebar + tag chips + grid) — on a
/// large library that made typing visibly crawl on slower Macs. Holding the draft
/// in LOCAL `@State` here confines each keystroke to this modifier's tiny body;
/// the name reaches AppState only on Create. Reset on each open since the modifier
/// (and its `@State`) outlives individual presentations.
private struct NameCollectionAlert: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .alert("Name Collection", isPresented: Binding(
                get: { appState.newCollectionRequest },
                set: { if !$0 { appState.cancelNewCollection() } }
            )) {
                TextField("Collection name", text: $draft)
                Button("Create") { appState.confirmNewCollection(name: draft) }
                Button("Cancel", role: .cancel) { appState.cancelNewCollection() }
            } message: {
                Text(appState.pendingNewCollectionPaths.isEmpty
                     ? "Creates a new collection."
                     : "Creates a collection from the selected images.")
            }
            .onChange(of: appState.newCollectionRequest) { _, open in
                if open { draft = "" }
            }
    }
}

/// The sidebar collection-rename prompt — the modal counterpart to folder
/// rename (`FolderNameAlerts`). Same local-`@State` draft trick as the other
/// name prompts so typing doesn't re-evaluate the whole ContentView. Seeded
/// with the collection's current name on open, keyed on the request's `id` so
/// re-targeting the same collection re-seeds (closing always passes nil first).
private struct CollectionRenameAlert: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename Collection", isPresented: Binding(
                get: { appState.collectionRenameAlertRequest != nil },
                set: { if !$0 { appState.collectionRenameAlertRequest = nil } }
            )) {
                TextField("Collection name", text: $draft)
                Button("Rename") {
                    if let req = appState.collectionRenameAlertRequest {
                        appState.collectionRenameAlertRequest = nil
                        appState.renameCollection(id: req.id, to: draft)
                    }
                }
                Button("Cancel", role: .cancel) { appState.collectionRenameAlertRequest = nil }
            } message: {
                Text("Renames the collection. Its images are kept.")
            }
            .onChange(of: appState.collectionRenameAlertRequest?.id) { _, id in
                if id != nil { draft = appState.collectionRenameAlertRequest?.currentName ?? "" }
            }
    }
}

/// The FILE rename prompt — same local-`@State` draft trick as the folder/
/// collection prompts so typing doesn't re-evaluate the whole ContentView. The
/// field holds only the STEM (base name); the locked extension is re-appended
/// inside AppState.renameFile. Seeded with the file's stem on open, keyed on the
/// request's `id` so re-targeting the same file re-seeds (closing passes nil).
private struct FileRenameAlert: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename File", isPresented: Binding(
                get: { appState.fileRenameRequest != nil },
                set: { if !$0 { appState.fileRenameRequest = nil } }
            )) {
                TextField("Name", text: $draft)
                Button("Rename") {
                    if let node = appState.fileRenameRequest {
                        appState.fileRenameRequest = nil
                        appState.renameFile(node, to: draft)
                    }
                }
                Button("Cancel", role: .cancel) { appState.fileRenameRequest = nil }
            } message: {
                let ext = FileNameSplit.split(appState.fileRenameRequest?.basename ?? "").ext
                // Separate Text literals (not a ternary) so each stays a
                // LocalizedStringKey — a ternary with an interpolated branch can
                // resolve to the non-localizing String overload (CLAUDE.md trap).
                if ext.isEmpty {
                    Text("Renames the file.")
                } else {
                    Text("The “\(ext)” extension is kept.")
                }
            }
            .onChange(of: appState.fileRenameRequest?.id) { _, id in
                if id != nil {
                    draft = FileNameSplit.split(appState.fileRenameRequest?.basename ?? "").stem
                }
            }
    }
}

/// The folder New-Subfolder / Rename prompts. Same trap as NameCollectionAlert:
/// binding the field to a `@Published` draft on AppState re-evaluated the whole
/// ContentView on every keystroke (laggy typing on slower Macs). The draft lives
/// in LOCAL `@State` here, reaching AppState only on Create/Rename. Both prompts
/// share one draft (only one is open at a time); it's seeded when either opens —
/// empty for a new subfolder, the current name for a rename. Keying `.onChange` on
/// the request's `id` (FolderNode isn't Equatable) still re-seeds when the SAME
/// folder is re-targeted, since closing always passes through nil first.
private struct FolderNameAlerts: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .alert("New Subfolder", isPresented: Binding(
                get: { appState.newSubfolderRequest != nil },
                set: { if !$0 { appState.newSubfolderRequest = nil } }
            )) {
                TextField("Folder name", text: $draft)
                Button("Create") {
                    if let node = appState.newSubfolderRequest {
                        appState.newSubfolderRequest = nil
                        appState.createSubfolder(named: draft, in: node)
                    }
                }
                Button("Cancel", role: .cancel) { appState.newSubfolderRequest = nil }
            } message: {
                Text("Creates a new folder inside “\(appState.newSubfolderRequest?.displayName ?? "")”.")
            }
            .alert("Rename Folder", isPresented: Binding(
                get: { appState.folderRenameRequest != nil },
                set: { if !$0 { appState.folderRenameRequest = nil } }
            )) {
                TextField("Folder name", text: $draft)
                Button("Rename") {
                    if let node = appState.folderRenameRequest {
                        appState.folderRenameRequest = nil
                        appState.renameFolder(node, to: draft)
                    }
                }
                Button("Cancel", role: .cancel) { appState.folderRenameRequest = nil }
            } message: {
                Text("Renames the folder on disk. Tags and collections are kept.")
            }
            .onChange(of: appState.newSubfolderRequest?.id) { _, id in
                if id != nil { draft = "" }
            }
            .onChange(of: appState.folderRenameRequest?.id) { _, id in
                if id != nil { draft = appState.folderRenameRequest?.displayName ?? "" }
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
