//
//  VocabularyLocalizer.swift
//  Muse
//
//  Display-time localization for AI (Vision) tag labels. Tag STORAGE stays
//  canonical-English; this maps canonical -> localized for rendering and
//  localized -> canonical for search. English (or any unknown term) is the
//  identity, so manual/user tags and untranslated vision terms pass through
//  unchanged. Pure value type; `nonisolated` so it's usable from any context
//  (the module's default actor isolation is MainActor).
//
//  See docs/superpowers/specs/2026-06-20-localization-french-design.md (§4B).
//

import Foundation

nonisolated struct VocabularyLocalizer {

    /// canonical(lowercased) -> localized term, for ONE language.
    private let forward: [String: String]
    /// localized(lowercased) -> canonical term, built from `forward`.
    private let reverse: [String: String]

    init(forward: [String: String]) {
        var fwd: [String: String] = [:]
        var rev: [String: String] = [:]
        for (canon, local) in forward {
            fwd[canon.lowercased()] = local
            rev[local.lowercased()] = canon
        }
        self.forward = fwd
        self.reverse = rev
    }

    /// English/identity localizer (no translations).
    static let identity = VocabularyLocalizer(forward: [:])

    /// Forward: canonical label -> localized term for display. Identity if the
    /// term is unknown (manual tags, untranslated vision terms).
    func display(_ canonical: String) -> String {
        forward[canonical.lowercased()] ?? canonical
    }

    /// Reverse: a localized token -> its canonical term, or nil if the token is
    /// not a known localized vision term. Case-insensitive.
    func canonicalize(_ token: String) -> String? {
        reverse[token.lowercased()]
    }

    /// Build a localizer for `language` from a nested `{canonical: {lang: term}}`
    /// table (the bundled VisionVocabulary.json shape). English (or no entries
    /// for the language) yields the identity localizer.
    init(table: [String: [String: String]], language: String) {
        guard language != "en" else { self.init(forward: [:]); return }
        var forward: [String: String] = [:]
        for (canon, byLang) in table {
            if let term = byLang[language] { forward[canon] = term }
        }
        self.init(forward: forward)
    }
}
