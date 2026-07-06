//
//  AppState+Selection.swift
//  Muse
//
//  Grid multi-selection: the Set of selected paths, Shift-range anchor, and
//  the click/select-all/effective-selection helpers. Split out of AppState
//  for readability (the stored @Published selection state lives in AppState).
//

import Foundation

extension AppState {

    /// Visible files in grid order, keyed by standardized path — the order
    /// Shift-range walks.
    var selectionOrder: [String] {
        visibleFiles.map { $0.url.standardizedFileURL.path }
    }

    func applyClick(_ click: GridSelection.Click) {
        let r = GridSelection.apply(click, to: selectedFiles,
                                    anchor: selectionAnchor, order: selectionOrder)
        selectedFiles = r.selection
        selectionAnchor = r.anchor
    }

    func clearSelection() {
        guard !selectedFiles.isEmpty || selectionAnchor != nil else { return }
        selectedFiles = []
        selectionAnchor = nil
    }

    /// Select every visible image (the Edit ▸ Select All command).
    func selectAllVisible() {
        let paths = selectionOrder
        selectedFiles = Set(paths)
        selectionAnchor = paths.first
    }

    /// Drop any selected paths the current filter/view now hides, so a
    /// filter-hidden file can never ride along into a selection action
    /// (Move to Folder / Add to Collection / Add Tag / Share / sidebar drop).
    /// "What you can't see can't be acted on" — mirrors the feat/next-41 rule
    /// that file-only flows must not silently act on out-of-view nodes. Called
    /// from `gridFilter`'s didSet; reads `selectionOrder` (= the freshly
    /// recomputed `visibleFiles`). A selected folder is pruned too if the
    /// "Folders" kind facet hid it.
    func pruneSelectionToVisible() {
        guard !selectedFiles.isEmpty else { return }
        let visible = Set(selectionOrder)
        let pruned = selectedFiles.intersection(visible)
        guard pruned.count != selectedFiles.count else { return }
        selectedFiles = pruned
        if let anchor = selectionAnchor, !visible.contains(anchor) {
            // Keep the replacement anchor deterministic + in grid order (like
            // selectAllVisible), not Set.first which is nondeterministic.
            selectionAnchor = selectionOrder.first { pruned.contains($0) }
        }
    }

    /// URLs for the effective selection (the selection, or `[fallback]` if the
    /// fallback path isn't part of the selection). An empty `fallback` yields
    /// only the current selection.
    func effectiveSelectionURLs(fallback path: String) -> [URL] {
        let paths: Set<String>
        if !path.isEmpty && !selectedFiles.contains(path) {
            paths = [path]
        } else {
            paths = selectedFiles
        }
        let byPath = Dictionary(visibleFiles.map { ($0.url.standardizedFileURL.path, $0.url) },
                                uniquingKeysWith: { a, _ in a })
        // Resolve from visibleFiles when possible; otherwise rebuild the URL
        // from the (absolute) path so a selected file that isn't currently in
        // view is never silently dropped from an action.
        return paths.map { byPath[$0] ?? URL(fileURLWithPath: $0) }
    }

    /// The index of the current highlighted tile within `files` (the grid
    /// order), derived from the selection anchor — the "current tile" for
    /// keyboard nav, deliberately distinct from the multi-select Set and already
    /// maintained on every click by GridSelection.apply. nil when nothing is
    /// highlighted yet (the first arrow then selects tile 0).
    func currentKeyboardIndex(order files: [FileNode]) -> Int? {
        guard let anchor = selectionAnchor else { return nil }
        return files.firstIndex { $0.url.standardizedFileURL.path == anchor }
    }

    /// Collapse the selection to exactly the highlighted tile and record it as
    /// the current tile. A plain arrow always yields a single-file selection;
    /// the anchor becomes the new highlight so the next arrow moves relative to
    /// it. This narrows the selection to a visible file (never widens it), so no
    /// pruning is needed.
    func keyboardSelect(path: String) {
        selectedFiles = [path]
        selectionAnchor = path
    }
}
