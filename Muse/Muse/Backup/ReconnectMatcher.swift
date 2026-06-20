//
//  ReconnectMatcher.swift
//  Muse
//
//  Pure classifier mapping backup occurrences onto on-disk files the indexer
//  already hashed. Exact (content hash) first, filename second, else unmatched.
//

import Foundation

nonisolated struct DiskFile: Equatable, Sendable {
    var path: String
    var basename: String
    var contentHash: String?
}

nonisolated enum MatchKind: Equatable, Sendable { case exact, nameOnly }

nonisolated struct OccurrenceMatch: Equatable, Sendable {
    var occurrence: BackupOccurrence
    var diskPath: String
    var kind: MatchKind
}

nonisolated struct MatchResult: Equatable, Sendable {
    var matches: [OccurrenceMatch]
    var unmatched: [BackupOccurrence]
}

nonisolated enum ReconnectMatcher {
    static func match(occurrences: [BackupOccurrence], disk: [DiskFile],
                      expectedHash: [String: String]) -> MatchResult {
        var consumed = Set<String>()                 // disk paths already taken
        var matches: [OccurrenceMatch] = []
        var stillOpen: [BackupOccurrence] = []

        // Index disk files by hash and by basename for O(1) pick.
        var byHash: [String: [DiskFile]] = [:]
        var byName: [String: [DiskFile]] = [:]
        for d in disk {
            if let h = d.contentHash { byHash[h, default: []].append(d) }
            byName[d.basename, default: []].append(d)
        }

        // Pass 1: exact hash matches for every occurrence first.
        for o in occurrences {
            guard let want = expectedHash[o.original_path],
                  let candidates = byHash[want] else { stillOpen.append(o); continue }
            if let pick = candidates.first(where: { !consumed.contains($0.path) }) {
                consumed.insert(pick.path)
                matches.append(OccurrenceMatch(occurrence: o, diskPath: pick.path, kind: .exact))
            } else {
                stillOpen.append(o)
            }
        }

        // Pass 2: name-only fallback for whatever's left.
        var unmatched: [BackupOccurrence] = []
        for o in stillOpen {
            if let candidates = byName[o.basename],
               let pick = candidates.first(where: { !consumed.contains($0.path) }) {
                consumed.insert(pick.path)
                matches.append(OccurrenceMatch(occurrence: o, diskPath: pick.path, kind: .nameOnly))
            } else {
                unmatched.append(o)
            }
        }
        return MatchResult(matches: matches, unmatched: unmatched)
    }
}
