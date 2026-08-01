//
//  EditReferenceStore.swift
//  Muse
//
//  The pinned reference photo for the editor's side-by-side pane.
//
//  Never persisted. A reference you set last Tuesday reappearing beside an
//  unrelated photo is noise, not continuity — Lightroom's equivalent is
//  session-scoped for the same reason. Pattern B, zero AppState integration.
//

import Foundation

@MainActor
final class EditReferenceStore: ObservableObject {
    static let shared = EditReferenceStore()

    @Published var url: URL?
    @Published var paneVisible = false

    init() {}
}
