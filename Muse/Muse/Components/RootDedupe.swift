//
//  RootDedupe.swift
//  Muse
//
//  Which library roots to keep when two of them point at the same folder.
//
//  Pure index math, split out of BookmarkStore so the rule can be tested without
//  security-scoped bookmarks or UserDefaults — the store keeps the side effects
//  (dropping the scope, persisting), this decides.
//

import Foundation

nonisolated enum RootDedupe {

    /// Indices to KEEP, given each root's resolved path in order. `nil` means
    /// that root's bookmark didn't resolve right now.
    ///
    /// - The first root at a given path wins; later ones are dropped.
    /// - An UNRESOLVED root is always kept and never counts as a duplicate.
    ///   Two roots that both fail to resolve are not "the same folder" — they're
    ///   two folders we can't see, e.g. an unplugged volume — and merging them
    ///   would silently discard one the user still has. Same fail-closed rule as
    ///   `PathReconciler.rootReachable` and `Housekeeping.pruneUnreachable`.
    static func keepIndices(resolvedPaths: [String?]) -> [Int] {
        var seen: Set<String> = []
        var keep: [Int] = []
        for (i, path) in resolvedPaths.enumerated() {
            guard let path else { keep.append(i); continue }
            if seen.insert(path).inserted { keep.append(i) }
        }
        return keep
    }
}
