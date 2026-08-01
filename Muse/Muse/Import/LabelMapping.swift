//
//  LabelMapping.swift
//  Muse
//
//  What the user decided to do with each incoming color-label value, and where
//  that decision is remembered.
//
//  Three choices per value (DECIDED #12): skip · namespaced `Label: X` ·
//  map to a tag of the user's own choosing. The ★-run refusal lives HERE, in
//  `resolvedLabel`, not in each caller — the same reasoning that put the
//  rating-glyph filter inside `TagSuggest.rank` and
//  `MetadataImportApply.applyKeywords`: a mapping target that is a run of ★
//  would attach a SECOND rating tag and break `StarRating.resolution`.
//
//  Choices persist keyed by the RAW source string, so a French Lightroom's
//  "Rouge" and an English "Red" are deliberately distinct keys — they are
//  different values in different catalogs, not the same one spelled twice.
//

import Foundation

nonisolated enum LabelMapping {
    enum Choice: Equatable, Codable, Hashable {
        case skip
        case namespaced
        case tag(String)
    }

    /// The tag label to write, or nil when nothing should be written.
    static func resolvedLabel(value: String, choice: Choice) -> String? {
        switch choice {
        case .skip:
            return nil
        case .namespaced:
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : LabelTag.make(trimmed)
        case .tag(let target):
            let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !StarRating.isRating(trimmed) else { return nil }
            return trimmed
        }
    }

    static func loadChoices() -> [String: Choice] {
        guard let data = UserDefaults.standard.data(forKey: AppSettings.importLabelChoicesKey),
              let decoded = try? JSONDecoder().decode([String: Choice].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Merges into whatever is already remembered — a run that mapped only the
    /// values it saw must not forget the others.
    static func saveChoices(_ choices: [String: Choice]) {
        var merged = loadChoices()
        for (key, value) in choices { merged[key] = value }
        guard let data = try? JSONEncoder().encode(merged) else { return }
        UserDefaults.standard.set(data, forKey: AppSettings.importLabelChoicesKey)
    }
}
