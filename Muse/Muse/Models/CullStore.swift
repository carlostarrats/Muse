//
//  CullStore.swift
//  Muse
//
//  Ephemeral keep/reject pass state. NOTHING PERSISTS — no table, no
//  UserDefaults key, no sidecar field. Quit mid-session and the marks are
//  gone, by construction: a cull pass is a working state, not a taxonomy.
//
//  The session is deliberately NOT in the Escape chain either — Escape keeps
//  meaning "back out of view layers", so an accidental press can never
//  discard an hour of marking. Finish/Cancel are the only exits.
//

import Foundation

@MainActor final class CullStore: ObservableObject {
    static let shared = CullStore()

    enum Mark: Equatable { case keep, reject }

    @Published private(set) var active = false
    @Published private(set) var marks: [String: Mark] = [:]

    func begin() {
        marks.removeAll()
        active = true
    }

    /// `nil` clears the mark. "Unmarked" isn't a case — it's the absence of an
    /// entry.
    func setMark(_ mark: Mark?, path: String) {
        guard active else { return }
        if let mark {
            marks[path] = mark
        } else {
            marks.removeValue(forKey: path)
        }
    }

    func mark(for path: String) -> Mark? { marks[path] }

    func end() {
        active = false
        marks.removeAll()
    }

    var summary: CullSummary { CullSummary(marks: marks) }
}
