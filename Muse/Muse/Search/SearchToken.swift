//
//  SearchToken.swift
//  Muse
//
//  The v1 search-token grammar: `key:value` pairs parsed out of the
//  `.searchable` field's committed text before every other search leg runs.
//
//  An unknown key or an empty/invalid value is NOT a token — it stays in
//  `freeText` verbatim, because typed text must never be silently dropped.
//  Keys are canonical English, matched case-insensitively; values are
//  language-neutral user data.
//
//  Grammar: no space before the colon; a double-quoted value carries spaces;
//  numeric ops are `>`, `>=`, `<`, `<=`, `a-b`, and a bare number means equals.
//  `star:N` means ≥ N; a literal ★-run parses as ≥ its length.
//

import Foundation

nonisolated enum SearchToken: Equatable, Sendable {
    case camera(String)
    case lens(String)
    case iso(NumericFilter)
    case aperture(NumericFilter)
    case inDate(DateToken)
    case near(String)
    case text(String)
    case color(String)
    case rating(atLeast: Int)
    case kind(SmartRule.KindGroup)
    case faces(NumericFilter)
    case pets(NumericFilter)
    case traitIs(TraitQuery)
    /// A similarity query is a VECTOR, which can't ride the field text — so it
    /// rides a session-scoped HANDLE resolved against `SimilarityRegistry` at
    /// query time. An unresolvable handle matches nothing, never the
    /// unfiltered set.
    case similar(handle: String)

    nonisolated enum TraitQuery: String, Equatable, Sendable, CaseIterable {
        case portrait, group
    }

    nonisolated struct NumericFilter: Equatable, Sendable {
        enum Op: Equatable, Sendable { case eq, gt, gte, lt, lte, range(Double, Double) }
        var op: Op
        var value: Double

        var displayLabel: String {
            func n(_ d: Double) -> String {
                d == d.rounded() ? String(Int(d)) : String(d)
            }
            switch op {
            case .eq: return n(value)
            case .gt: return ">\(n(value))"
            case .gte: return "≥\(n(value))"
            case .lt: return "<\(n(value))"
            case .lte: return "≤\(n(value))"
            case let .range(lo, hi): return "\(n(lo))–\(n(hi))"
            }
        }
    }

    nonisolated struct DateToken: Equatable, Sendable {
        var year: Int
        var month: Int?
        var day: Int?

        var displayLabel: String {
            var out = String(format: "%04d", year)
            if let month { out += String(format: "-%02d", month) }
            if let day { out += String(format: "-%02d", day) }
            return out
        }
    }

    /// Chip-bar label. Keys are localized for DISPLAY only — the stored/parsed
    /// key stays canonical English.
    var displayLabel: String {
        switch self {
        case let .camera(v):    return "\(String(localized: "camera")): \(v)"
        case let .lens(v):      return "\(String(localized: "lens")): \(v)"
        case let .iso(f):       return "\(String(localized: "ISO")) \(f.displayLabel)"
        case let .aperture(f):  return "ƒ \(f.displayLabel)"
        case let .inDate(d):    return "\(String(localized: "in")): \(d.displayLabel)"
        case let .near(v):      return "\(String(localized: "near")): \(v)"
        case let .text(v):      return "\(String(localized: "text")): \u{201C}\(v)\u{201D}"
        case let .color(v):     return "\(String(localized: "color")): \(v)"
        case let .rating(n):    return String(repeating: "★", count: n) + "+"
        case let .kind(g):      return "\(String(localized: "kind")): \(g.rawValue)"
        case let .faces(f):     return "\(String(localized: "faces")) \(f.displayLabel)"
        case let .pets(f):      return "\(String(localized: "pets")) \(f.displayLabel)"
        case let .traitIs(q):
            switch q {
            case .portrait: return String(localized: "Portrait")
            case .group:    return String(localized: "Group photo")
            }
        case let .similar(handle):
            // A handle whose entry is gone (a new session, a cleared registry)
            // must SAY so — the chip is the only sign the filter is on.
            if let entry = SimilarityRegistry.shared.entry(for: handle) {
                return "\(String(localized: "similar")): \(entry.label)"
            }
            return String(localized: "Similar (expired)")
        }
    }
}

nonisolated struct ParsedQuery: Equatable {
    var tokens: [SearchToken]
    var freeText: String
    /// Every ORIGINAL space-separated segment, in order (tokens and free-text
    /// words interleaved) — what makes `removing(tokenAt:)` an exact
    /// reconstruction rather than a re-serialization.
    private var rawSegments: [String]

    init(tokens: [SearchToken], freeText: String, rawSegments: [String]) {
        self.tokens = tokens
        self.freeText = freeText
        self.rawSegments = rawSegments
    }

    static func == (lhs: ParsedQuery, rhs: ParsedQuery) -> Bool {
        lhs.tokens == rhs.tokens && lhs.freeText == rhs.freeText
    }

    /// Rebuild the query string minus the token at `index` — the chip ✕
    /// operation. The committed field text is the single source of truth for
    /// tokens, so editing a token means rewriting that text.
    func removing(tokenAt index: Int) -> String {
        guard tokens.indices.contains(index) else {
            return rawSegments.joined(separator: " ")
        }
        var tokenOccurrence = -1
        var kept: [String] = []
        for segment in rawSegments {
            if SearchQueryParser.isTokenSegment(segment) {
                tokenOccurrence += 1
                if tokenOccurrence == index { continue }
            }
            kept.append(segment)
        }
        return kept.joined(separator: " ")
    }
}

nonisolated enum SearchQueryParser {
    private static let starGlyph: Character = "★"

    /// Every canonical key, in the order autocomplete offers them.
    static let keys = ["camera", "lens", "iso", "f", "in", "near", "text", "color", "star", "kind",
                       "faces", "pets", "is"]

    static func parse(_ raw: String) -> ParsedQuery {
        let segments = splitRespectingQuotes(raw)
        var tokens: [SearchToken] = []
        var freeWords: [String] = []
        for segment in segments {
            if let token = parseSegment(segment) {
                tokens.append(token)
            } else {
                freeWords.append(segment)
            }
        }
        return ParsedQuery(tokens: tokens, freeText: freeWords.joined(separator: " "),
                           rawSegments: segments)
    }

    static func isTokenSegment(_ segment: String) -> Bool {
        parseSegment(segment) != nil
    }

    /// Splits on whitespace but keeps a `key:"quoted value"` run intact.
    private static func splitRespectingQuotes(_ raw: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var insideQuotes = false
        for char in raw {
            if char == "\"" {
                insideQuotes.toggle()
                current.append(char)
            } else if char.isWhitespace && !insideQuotes {
                if !current.isEmpty { segments.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private static func parseSegment(_ segment: String) -> SearchToken? {
        // A bare star-run ("★★★★") is a token with no key:value shape at all.
        if !segment.isEmpty, segment.allSatisfy({ $0 == starGlyph }) {
            return .rating(atLeast: segment.count)
        }
        if segment.hasPrefix("★≥") || segment.hasPrefix("★>=") {
            let numPart = segment.hasPrefix("★≥") ? segment.dropFirst(2) : segment.dropFirst(3)
            guard let n = Int(numPart), (1...StarRating.maxStars).contains(n) else { return nil }
            return .rating(atLeast: n)
        }
        guard let colonIndex = segment.firstIndex(of: ":") else { return nil }
        let key = segment[segment.startIndex..<colonIndex].lowercased()
        guard !key.isEmpty else { return nil }
        var value = String(segment[segment.index(after: colonIndex)...])
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty else { return nil }

        switch key {
        case "camera": return .camera(value)
        case "lens":   return .lens(value)
        case "iso":    return parseNumericFilter(value).map(SearchToken.iso)
        case "f":      return parseNumericFilter(value).map(SearchToken.aperture)
        case "in":     return parseDateToken(value).map(SearchToken.inDate)
        case "near":   return .near(value)
        case "text":   return .text(value)
        case "color":  return .color(value)
        case "star":
            // `star:=N` is the exact form; both surface as a rating token —
            // the ≥/= nuance is not exposed in v1's model.
            let digits = value.hasPrefix("=") ? String(value.dropFirst()) : value
            guard let n = Int(digits), (1...StarRating.maxStars).contains(n) else { return nil }
            return .rating(atLeast: n)
        case "kind":
            guard let group = SmartRule.KindGroup(rawValue: value.lowercased()) else { return nil }
            return .kind(group)
        case "faces": return parseNumericFilter(value).map(SearchToken.faces)
        case "pets":  return parseNumericFilter(value).map(SearchToken.pets)
        case "is":
            // An unrecognized is: value is NOT a token — it stays free text, so
            // "is: that photo of us" can't be silently eaten.
            guard let query = SearchToken.TraitQuery(rawValue: value.lowercased()) else { return nil }
            return .traitIs(query)
        case "similar":
            // Handle shape only: `s` + digits. Anything else stays free text.
            guard value.count > 1, value.hasPrefix("s"),
                  value.dropFirst().allSatisfy(\.isNumber) else { return nil }
            return .similar(handle: value)
        default:
            return nil
        }
    }

    private static func parseNumericFilter(_ value: String) -> SearchToken.NumericFilter? {
        if value.hasPrefix(">="), let n = Double(value.dropFirst(2)) { return .init(op: .gte, value: n) }
        if value.hasPrefix("<="), let n = Double(value.dropFirst(2)) { return .init(op: .lte, value: n) }
        if value.hasPrefix("≥"), let n = Double(value.dropFirst()) { return .init(op: .gte, value: n) }
        if value.hasPrefix("≤"), let n = Double(value.dropFirst()) { return .init(op: .lte, value: n) }
        if value.hasPrefix(">"), let n = Double(value.dropFirst()) { return .init(op: .gt, value: n) }
        if value.hasPrefix("<"), let n = Double(value.dropFirst()) { return .init(op: .lt, value: n) }
        if value.contains("-"), !value.hasPrefix("-") {
            let parts = value.split(separator: "-", maxSplits: 1)
            if parts.count == 2, let lo = Double(parts[0]), let hi = Double(parts[1]) {
                return .init(op: .range(lo, hi), value: lo)
            }
        }
        if let n = Double(value) { return .init(op: .eq, value: n) }
        return nil
    }

    private static func parseDateToken(_ value: String) -> SearchToken.DateToken? {
        let parts = value.split(separator: "-").map(String.init)
        guard let first = parts.first, first.count == 4, let year = Int(first) else { return nil }
        guard parts.count <= 3 else { return nil }
        var month: Int?
        var day: Int?
        if parts.count > 1 {
            guard let m = Int(parts[1]), (1...12).contains(m) else { return nil }
            month = m
        }
        if parts.count > 2 {
            guard let d = Int(parts[2]), (1...31).contains(d) else { return nil }
            day = d
        }
        return SearchToken.DateToken(year: year, month: month, day: day)
    }
}
