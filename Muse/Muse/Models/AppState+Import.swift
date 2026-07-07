//
//  AppState+Import.swift
//  Muse
//
//  File > Import Keywords & Ratings… — the read-only metadata import
//  (Lightroom / Bridge / Capture One keywords + stars → Muse manual tags +
//  ratings). Spec: docs/superpowers/specs/2026-07-07-metadata-keywords-
//  import-design.md. The Eagle-library import was designed but deferred:
//  docs/future-features/eagle-library-import.md.
//

import AppKit
import Foundation

/// One requested import run; Identifiable so ContentView presents it via
/// .sheet(item:) and a second request is a fresh sheet.
struct MetadataImportRequest: Identifiable, Equatable {
    let id = UUID()
    let folder: URL
}

extension AppState {

    /// Folder-only picker → import. A folder outside every root is added as
    /// a sidebar root first (the standard addRoot flow — it activates before
    /// appending) so the imported tags have rows to land on and the user can
    /// see the result. A folder already under a root is used as-is
    /// (containment via the trailing-slash prefix rule).
    func importKeywordsAndRatings() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Select a folder of images — keywords and ratings written by Lightroom, Bridge, or Capture One will be imported as Muse tags and ratings.")
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let std = url.standardizedFileURL
        let covered = rootNodes.contains {
            let root = $0.url.standardizedFileURL.path
            return std.path == root || std.path.hasPrefix(root + "/")
        }
        if !covered {
            _ = bookmarks.addRoot(at: std)
        }
        metadataImportRequest = MetadataImportRequest(folder: std)
    }
}
