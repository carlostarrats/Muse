//
//  EscapeAction.swift
//  Muse
//
//  Pure priority resolver for the Escape key. Escape backs out of the current
//  focused context, innermost-first, so it can double as the keyboard
//  accelerator for the visible back buttons without ever disturbing the
//  delicate hero-close path. Any open viewer wins outright (Escape closes it,
//  exactly as before); only with no viewer open does Escape pop a collection,
//  then the Collections page, then nothing. No I/O — unit tested; ContentView
//  feeds it live AppState flags and maps the result onto the existing calls.
//
//  See the 2026-06-18 hero-close gotcha: the hero path must keep firing ONLY
//  viewerClosing. This resolver never returns a back-out while a viewer is
//  open, so the back-out logic can't interleave with that close sequence.
//

enum EscapeAction: Equatable {
    /// Image/raw/psd hero viewer open — run its return flight (viewerClosing).
    case closeHero
    /// A non-hero viewer (PDF, video, …) open — clear the selected file.
    case closeViewer
    /// An active/typed search — clear it (clearSearch()).
    case clearSearch
    /// An active multi-tag chip selection — clear the WHOLE set (setActiveTag(nil)).
    case clearTags
    /// Inside a collection — pop to the Collections page (setActiveCollection(nil)).
    case exitCollection
    /// On the Collections card page — return to the grid (toggleCollectionsPage()).
    case exitCollectionsPage
    /// Plain grid — Escape does nothing.
    case none
}

enum EscapeResolver {
    /// Resolve what Escape should do given the current shell state. Escape peels
    /// the most recent layer first: an open viewer, then an active search, then a
    /// collection, then the Collections page. Search sits ABOVE the collection
    /// back-out because a search runs WITHOUT clearing the collection underneath
    /// (it just overrides what the grid shows) — so peeling the search returns to
    /// the collection's own members rather than silently dropping the collection
    /// while results still show. `.exitCollection` lands on the Collections page
    /// (not the bare grid) because `showingCollections` stays true the whole time
    /// a collection is open — every opener originates from that page.
    /// `selectedFileIsHero` is only consulted when `hasSelectedFile` is true. The
    /// tag-set layer sits between search and the collection back-out: a tag
    /// filter narrows WITHIN the current view (folder or collection), so Escape
    /// clears the whole set first (one press), then a further press exits the
    /// collection. It's peeled after search to mirror the chain (a search runs
    /// over whatever the tags left showing).
    static func action(hasSelectedFile: Bool,
                       selectedFileIsHero: Bool,
                       searchActive: Bool,
                       tagsActive: Bool,
                       insideCollection: Bool,
                       showingCollectionsPage: Bool) -> EscapeAction {
        if hasSelectedFile {
            return selectedFileIsHero ? .closeHero : .closeViewer
        }
        if searchActive { return .clearSearch }
        if tagsActive { return .clearTags }
        if insideCollection { return .exitCollection }
        if showingCollectionsPage { return .exitCollectionsPage }
        return .none
    }

    /// Whether a search is "present" for back-out purposes: active results OR a
    /// typed query whose debounce hasn't fired yet. Mirrors selectFolder's
    /// teardown check so Escape peels an in-flight search too. Feeds `searchActive`.
    static func searchPresent(isSearchActive: Bool, queryIsEmpty: Bool) -> Bool {
        isSearchActive || !queryIsEmpty
    }
}
