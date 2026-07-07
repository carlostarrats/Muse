//
//  SmartRule.swift
//  Muse
//
//  The pure, Codable model behind a smart collection: a Match.all/.any set of
//  rules over the axes Muse already stores (rating, color, tags, kind, date,
//  filename, size). No I/O — SmartCollectionResolver evaluates these against
//  the DB. Persisted as JSON in collections.smart_rules (v12).
//

import Foundation

/// AND (`all`) / OR (`any`) over a list of rules. A smart collection stores one.
struct SmartRuleSet: Codable, Equatable {
    enum Match: String, Codable { case all, any }
    var match: Match
    var rules: [SmartRule]

    /// Savable iff there's at least one rule and every rule is valid.
    var isValid: Bool { !rules.isEmpty && rules.allSatisfy(\.isValid) }

    func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String) -> SmartRuleSet? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SmartRuleSet.self, from: data)
    }
}

/// `≥ / = / ≤` — shared by rating and size.
enum Comparison: String, Codable { case atLeast, equal, atMost }
enum HasOp: String, Codable { case has, hasNot }
enum DateField: String, Codable { case created, modified }

/// A color rule term: a palette color name or a hex string.
enum ColorTerm: Codable, Equatable {
    case name(String)
    case hex(String)
}

/// Relative or absolute date bound. Dates are epoch seconds (files.created_at).
enum DateOp: Codable, Equatable {
    case withinDays(Int)
    case before(Int64)
    case after(Int64)
}

enum SmartRule: Codable, Equatable {
    case rating(op: Comparison, stars: Int)
    case color(ColorTerm)
    case tag(op: HasOp, label: String)
    case kind(KindGroup)
    case date(field: DateField, op: DateOp)
    case filename(contains: String)
    case size(op: Comparison, bytes: Int64)

    /// A display-friendly grouping of AssetKind values (files.kind rawValue).
    enum KindGroup: String, Codable, CaseIterable {
        case image, raw, pdf, video, audio, document

        /// The AssetKind rawValues this group matches in files.kind.
        var kinds: [String] {
            switch self {
            case .image:    return ["image", "psd", "svg"]
            case .raw:      return ["raw"]
            case .pdf:      return ["pdf"]
            case .video:    return ["video"]
            case .audio:    return ["audio"]
            case .document: return ["text", "markdown", "code", "office"]
            }
        }
    }

    var isValid: Bool {
        switch self {
        case let .rating(_, stars):        return (1...5).contains(stars)
        case let .color(term):
            switch term {
            case let .name(n): return !n.trimmingCharacters(in: .whitespaces).isEmpty
            case let .hex(h):  return SmartRule.parsedHex(h) != nil
            }
        case let .tag(_, label):           return !label.trimmingCharacters(in: .whitespaces).isEmpty
        case .kind:                        return true
        case let .date(_, op):
            if case let .withinDays(d) = op { return d > 0 }
            return true
        case let .filename(contains):      return !contains.isEmpty
        case let .size(_, bytes):          return bytes > 0
        }
    }

    /// Decode a rule's hex term to sRGB 0…1 (via NamedColor). `#` optional,
    /// 3-digit shorthand expands. Returns nil for a non-hex string.
    static func parsedHex(_ raw: String) -> RGB? {
        var s = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let (r, g, b) = NamedColor.parse(s) else { return nil }
        return RGB(r: r, g: g, b: b)
    }
}
