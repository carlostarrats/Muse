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

    /// The Collections page is the card grid — showing collections with no
    /// single collection drilled into (and not while searching).
    private var isCollectionsPage: Bool {
        appState.showingCollections
            && appState.activeCollectionID == nil
            && !appState.isSearchActive
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
                                if !appState.isSearchActive {
                                    TagChipsRow()
                                        .transition(.opacity)
                                }
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
            .toolbar {
                // Far left, beside the sidebar toggle — fully separate from search.
                // Sort mode + its direction arrow share ONE item (an HStack) so
                // macOS renders them as a single "sorting" cluster — otherwise
                // separate adjacent items fuse the arrow into the folder
                // (show-subfolders) cluster on its right.
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 2) {
                        // The sort menu + direction arrow are live on the
                        // Collections page (they sort the cards) and on the grid;
                        // only search disables them (results are ranked by
                        // relevance). The funnel sits BETWEEN sort-by and the
                        // direction arrow and has the OPPOSITE enablement: live
                        // during search (it narrows results) but dead on the
                        // Collections CARD page (cards aren't filtered) — so each
                        // control carries its own `.disabled`, not the HStack.
                        sortMenu
                            .disabled(appState.isSearchActive)
                        filterMenu
                            .disabled(isCollectionsPage)
                        // Flip the active sort mode's direction (newest↔oldest, A↔Z, …).
                        sortDirectionButton
                            .disabled(appState.isSearchActive)
                    }
                }

                // Tag-chip sort order (Most Used / A→Z) — its own item, sitting
                // between the grid sort cluster and the show-subfolders toggle.
                ToolbarItem(placement: .navigation) {
                    tagSortMenu
                        // The tag chips don't show on the Collections card page
                        // or during a search.
                        .disabled(isCollectionsPage || appState.isSearchActive)
                }

                // Its own item (own surface), sitting next to sort.
                ToolbarItem(placement: .navigation) {
                    Toggle(isOn: $appState.showSubfolders) {
                        Image(systemName: "rectangle.stack")
                            .moodToolbarIcon(appState.moodPalette,
                                             selected: appState.showSubfolders)
                    }
                    .help(appState.showSubfolders
                          ? "Hide files inside subfolders"
                          : "Show files inside subfolders")
                    // Icon-only toggle: give VoiceOver a stable name (its on/off
                    // state is announced by the toggle itself).
                    .accessibilityLabel("Show files in subfolders")
                    .onChange(of: appState.showSubfolders) { _, _ in
                        appState.toggleSubfolders()
                    }
                    // Toggling subfolders mid-search re-loads the whole folder
                    // listing, dropping you out of the results — confusing.
                    .disabled(appState.isSearchActive)
                }

                ToolbarItem(placement: .principal) {
                    SearchBar()
                }

                // Collections page toggle — sits to the LEFT of the mood
                // (color) button. No selected/blue state: it's navigation with
                // its own back button, not a sticky mode you toggle off here.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appState.toggleCollectionsPage()
                    } label: {
                        Image(systemName: "square.stack.3d.up")
                            .moodToolbarIcon(appState.moodPalette)
                    }
                    .help("Collections")
                    .accessibilityLabel("Collections")
                    // Toggling collections mid-search yanks you out of the
                    // search and (in a library-wide search) re-highlights a
                    // folder — confusing. Disable until the search is cleared.
                    .disabled(appState.isSearchActive)
                }

                // Image Layout — sits between Collections and the mood (color)
                // button. Opens the layout modal; the choice applies to every
                // grid instantly.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        imageLayoutShown = true
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .moodToolbarIcon(appState.moodPalette)
                    }
                    .help("Image Layout")
                    // Icon-only button: give VoiceOver an explicit name (the
                    // SF Symbol's derived label reads "square grid 2x2").
                    .accessibilityLabel("Image Layout")
                    // Same as Collections: layout has no meaning over ranked
                    // search results.
                    .disabled(appState.isSearchActive)
                }

                // Mood and info grouped together as one cluster (macOS fuses
                // adjacent trailing items; a ToolbarSpacer would separate them
                // but only with a wider-than-default gap).
                ToolbarItem(placement: .primaryAction) {
                    moodMenu
                }

                ToolbarItem(placement: .primaryAction) {
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
            // Transparent title bar so the sidebar card flows continuously up
            // to the top and curves with the window corner (Lineform-style).
            .toolbarBackground(.hidden, for: .windowToolbar)
            // No window title — the toolbar starts at the search bar.
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
                // typed-but-not-yet-fired query (debounce in flight) is peeled too.
                let searchPresent = EscapeResolver.searchPresent(
                    isSearchActive: appState.isSearchActive,
                    queryIsEmpty: appState.searchQuery.isEmpty)
                switch EscapeResolver.action(
                    hasSelectedFile: selected != nil,
                    selectedFileIsHero: isHero,
                    searchActive: searchPresent,
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
                    appState.selectedFile = nil
                case .clearSearch:
                    // Peel the search first (it left any collection intact), so
                    // this returns to the collection's members or the folder grid.
                    appState.clearSearch()
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
        // sidebar context menu and the menu-bar Edit menu). The text field binds
        // to appState.folderNameDraft, which the request helpers seed, so a
        // re-targeted same folder still resets the field.
        .alert("New Subfolder", isPresented: Binding(
            get: { appState.newSubfolderRequest != nil },
            set: { if !$0 { appState.newSubfolderRequest = nil } }
        )) {
            TextField("Folder name", text: $appState.folderNameDraft)
            Button("Create") {
                if let node = appState.newSubfolderRequest {
                    appState.newSubfolderRequest = nil
                    appState.createSubfolder(named: appState.folderNameDraft, in: node)
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
            TextField("Folder name", text: $appState.folderNameDraft)
            Button("Rename") {
                if let node = appState.folderRenameRequest {
                    appState.folderRenameRequest = nil
                    appState.renameFolder(node, to: appState.folderNameDraft)
                }
            }
            Button("Cancel", role: .cancel) { appState.folderRenameRequest = nil }
        } message: {
            Text("Renames the folder on disk. Tags and collections are kept.")
        }
        .alert("Folder", isPresented: Binding(
            get: { appState.folderOpError != nil },
            set: { if !$0 { appState.folderOpError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.folderOpError = nil }
        } message: {
            Text(appState.folderOpError ?? "")
        }
        .alert("Name Collection", isPresented: Binding(
            get: { appState.newCollectionRequest },
            set: { if !$0 { appState.cancelNewCollection() } }
        )) {
            TextField("Collection name", text: $appState.newCollectionNameDraft)
            Button("Create") { appState.confirmNewCollection() }
            Button("Cancel", role: .cancel) { appState.cancelNewCollection() }
        } message: {
            Text(appState.pendingNewCollectionPaths.isEmpty
                 ? "Creates a new collection."
                 : "Creates a collection from the selected images.")
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
        .accessibilityLabel("Sort direction: " + mode.directionLabel(ascending: ascending))
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
        .help(appState.gridFilter.isActive ? "Filter (active)" : "Filter")
        .accessibilityLabel("Filter")
        // The toggle's "on" state doubles for popover-open, so announce the
        // actual filter state separately (keeps the stable name "Filter").
        .accessibilityValue(appState.gridFilter.isActive ? "Active" : "Off")
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
