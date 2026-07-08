//
//  MetadataImportRules.swift
//  Muse
//
//  Pure rules for the keywords & ratings import (File > Import Keywords &
//  Ratings…). Kept UI/DB-free so the conflict semantics are unit-tested:
//  keywords merge, ratings only fill gaps — a rating set in Muse is never
//  clobbered by an import, and re-running an import changes nothing.
//

import Foundation

enum MetadataImportRules {

    /// Trim whitespace, drop empties, dedupe case-insensitively (the first
    /// spelling wins), preserving order. Keywords are stored VERBATIM as
    /// canonical labels — user words, same as hand-typed tags (no
    /// VisionVocabulary row).
    static func normalizeKeywords(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for keyword in raw {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed.lowercased()).inserted { out.append(trimmed) }
        }
        return out
    }

    /// XMP `xmp:Rating` / IPTC star rating → Muse stars. 1–5 pass (above 5
    /// clamps to 5); 0 (unrated), negative (Lightroom's −1 "rejected"), or
    /// absent → nil.
    static func normalizeRating(_ raw: Double?) -> Int? {
        guard let raw, raw.isFinite else { return nil }
        // Clamp to [0, maxStars] BEFORE `Int(...)` — a corrupt/hand-edited
        // xmp:Rating text can parse to NaN/inf/1e20, and `Int()` on a non-finite
        // or out-of-Int64-range Double is a fatal trap (it fires inside the
        // import's detached read, uncatchable). Anything ≥1 then rounds and caps.
        let clamped = min(max(raw.rounded(), 0), Double(StarRating.maxStars))
        let rounded = Int(clamped)
        guard rounded >= 1 else { return nil }
        return rounded
    }

    /// Import fills rating gaps only: returns the stars to write, or nil when
    /// nothing should be written (no imported rating, or the user already
    /// rated the file in Muse).
    static func ratingToApply(imported: Int?, existingHasRating: Bool) -> Int? {
        guard let imported, !existingHasRating else { return nil }
        return imported
    }
}
