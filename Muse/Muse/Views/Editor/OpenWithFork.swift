//
//  OpenWithFork.swift
//  Muse
//
//  The SINGLE seam every external hand-off goes through.
//
//  Muse edits live in Muse's database, not in the file, so opening an edited
//  photo in another app hands over the ORIGINAL pixels — the user's
//  adjustments are simply absent, and the reasonable conclusion is that Muse
//  threw them away. So a file with edits asks first. A file without edits opens
//  exactly as it always did, with no extra click.
//
//  Every "Open" and "Open With" call site routes here for that reason: one
//  that didn't would be the one that silently loses the edits.
//

import AppKit

@MainActor
enum OpenWithFork {
    static func open(url: URL, appURL: URL?, appState: AppState) {
        guard EditStackIndex.stackHash(for: url) != nil else {
            launch(url: url, appURL: appURL)
            return
        }
        appState.openWithForkRequest = OpenWithForkRequest(fileURL: url, appURL: appURL)
    }

    static func launch(url: URL, appURL: URL?) {
        if let appURL {
            NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
