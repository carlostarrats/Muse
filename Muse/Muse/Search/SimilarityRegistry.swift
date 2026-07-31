//
//  SimilarityRegistry.swift
//  Muse
//
//  A similarity query is a VECTOR, which cannot ride the field text — but the
//  field text stays the single source of truth for tokens. This bridges the
//  two via session-scoped handles: `similar:s1` in the query text resolves
//  against this registry at query time.
//
//  Deliberately NOT persisted and NOT an ObservableObject: the handles die
//  with the session (a stale one is shown as "Similar (expired)" and matches
//  nothing), and `displayLabel` is a nonisolated read, so the storage is a
//  plain lock rather than actor isolation.
//

import Foundation

nonisolated final class SimilarityRegistry: @unchecked Sendable {
    static let shared = SimilarityRegistry()

    struct Entry: Sendable { let vector: [Float]; let label: String }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var counter = 0

    @discardableResult
    func stash(vector: [Float], label: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        let handle = "s\(counter)"
        entries[handle] = Entry(vector: vector, label: label)
        return handle
    }

    func entry(for handle: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[handle]
    }

    var snapshot: [String: [Float]] {
        lock.lock()
        defer { lock.unlock() }
        return entries.mapValues(\.vector)
    }
}
