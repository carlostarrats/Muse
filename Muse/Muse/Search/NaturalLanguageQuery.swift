//
//  NaturalLanguageQuery.swift
//  Muse
//
//  Foundation Models guided generation fills a structured intent; the intent
//  is composed into TOKEN TEXT; the token text round-trips through
//  SearchQueryParser — which stays the single source of truth. By
//  construction this can never be a black box: every result is visible,
//  editable tokens the user can remove one at a time.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@Generable struct NLSearchIntent {
    @Guide(description: "Four-digit year the photos were taken, if stated")
    var year: Int?
    @Guide(description: "Month 1-12, only if a specific month is stated")
    var month: Int?
    @Guide(description: "City, region or country named in the query")
    var place: String?
    @Guide(description: "Camera make or model named in the query")
    var camera: String?
    @Guide(description: "Minimum star rating 1-5, only if the query asks for rated or best photos")
    var minStars: Int?
    @Guide(description: "What the photos should look like or contain, in a few words")
    var subject: String?
}
#endif

nonisolated enum NLTokenComposer {
    /// Compose the intent into text the REAL parser understands. Every
    /// fragment below is written in the grammar SearchQueryParser already
    /// implements — `NLTokenComposerTests` is the guard that catches a drift.
    static func compose(year: Int?, month: Int?, place: String?, camera: String?,
                        minStars: Int?, subject: String?) -> String {
        var parts: [String] = []
        if let year {
            if let month, (1...12).contains(month) {
                parts.append("in:\(year)-\(String(format: "%02d", month))")
            } else {
                parts.append("in:\(year)")
            }
        }
        if let place, !place.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("near:\(quoted(place))")
        }
        if let camera, !camera.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("camera:\(quoted(camera))")
        }
        if let minStars, (1...StarRating.maxStars).contains(minStars) {
            parts.append("star:\(minStars)")
        }
        if let subject, !subject.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(subject.trimmingCharacters(in: .whitespaces))
        }
        return parts.joined(separator: " ")
    }

    /// A value with spaces has to be quoted or it re-parses as two segments
    /// and stops being one token.
    private static func quoted(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.contains(" ") ? "\"\(trimmed)\"" : trimmed
    }
}
