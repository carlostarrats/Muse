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
}
