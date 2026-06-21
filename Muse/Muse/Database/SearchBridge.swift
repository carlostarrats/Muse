//
//  SearchBridge.swift
//  Muse
//
//  Pure helper for the tag-search half of SearchService: expand a user query
//  into the set of tag-label terms to LIKE-match. Always includes the raw query
//  (so French filenames/OCR/captions still match) and adds the canonical English
//  term whenever the whole query OR any whitespace token is a known localized
//  vision term — so a French user typing `plage` finds files tagged canonical
//  `beach`. `nonisolated` (module default actor isolation is MainActor).
//
//  See docs/superpowers/specs/2026-06-20-localization-french-design.md (§4C).
//

import Foundation

nonisolated enum SearchBridge {

    /// The tag-label terms to LIKE-match for `query`, de-duplicated and in a
    /// stable order: the raw query first, then any canonical forms discovered
    /// (whole query, then per whitespace token).
    static func tagSearchTerms(for query: String,
                               canonicalize: (String) -> String?) -> [String] {
        var terms = [query]
        if let c = canonicalize(query) { terms.append(c) }
        for token in query.split(whereSeparator: { $0.isWhitespace }) {
            if let c = canonicalize(String(token)) { terms.append(c) }
        }
        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }
    }
}
