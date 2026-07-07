//
//  ColorSearch.swift
//  Muse
//
//  Pure logic for matching search queries by color. A hex token in the
//  search bar (`#3a7bd5`, or a pasted `#3a7bd5, #f0e0c0, #202020` from the
//  hero COLORS card) is matched perceptually — LAB distance, "near" not
//  "exact" — against each analyzed file's stored `palette`.
//
//  Three units, all pure + unit-tested:
//    • ColorQuery   — pull hex tokens out of the query string.
//    • LabColor / ColorDistance — sRGB → LAB + CIE76 ΔE.
//    • PaletteMatch — does a file's palette satisfy every query color (AND)?
//
//  SearchService.search is the single integration point.
//

import Foundation

/// An sRGB color, components in 0…1.
struct RGB: Equatable {
    let r, g, b: Double
}

/// A color in CIE L*a*b* (D65). Perceptually near-uniform, so Euclidean
/// distance here is a reasonable "how different do these look" metric.
struct LabColor: Equatable {
    let L, a, b: Double

    init(L: Double, a: Double, b: Double) {
        self.L = L; self.a = a; self.b = b
    }

    init(rgb: RGB) {
        // sRGB companding → linear light.
        func lin(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = lin(rgb.r), g = lin(rgb.g), b = lin(rgb.b)

        // linear sRGB → XYZ (D65).
        let x = r * 0.4124564 + g * 0.3575761 + b * 0.1804375
        let y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750
        let z = r * 0.0193339 + g * 0.1191920 + b * 0.9503041

        // Normalize by the D65 reference white.
        let xn = x / 0.95047, yn = y / 1.00000, zn = z / 1.08883
        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t) + (16.0 / 116.0)
        }
        let fx = f(xn), fy = f(yn), fz = f(zn)

        self.L = (116.0 * fy) - 16.0
        self.a = 500.0 * (fx - fy)
        self.b = 200.0 * (fy - fz)
    }
}

enum ColorDistance {
    /// CIE76 — plain Euclidean distance in LAB. Correct-enough for v1;
    /// CIEDE2000 is a drop-in upgrade behind this same signature later.
    static func deltaE(_ x: LabColor, _ y: LabColor) -> Double {
        let dL = x.L - y.L, da = x.a - y.a, db = x.b - y.b
        return (dL * dL + da * da + db * db).squareRoot()
    }

    /// "Near" cutoff (ΔE76). A single internal constant, NOT a user setting.
    /// ≈25 is a first guess, tuned against real images during implementation.
    static let nearThreshold: Double = 25
}

/// Classifies a raw search string into color tokens + a text remainder.
/// A hex token is `#?` followed by exactly 3 or 6 hex digits (3-digit
/// shorthand expands to 6). Everything else is re-joined, in order, as text
/// and flows through the existing search pipeline verbatim.
///
/// Bare-hex guard: a `#`-less token is treated as a color only when it is
/// *exactly* 6 (or 3) hex digits. This is the one accepted false-positive
/// (a literal all-hex-digit word like `c0ffee`, or a 3-letter word like
/// `bad`, reads as a color) — accepted because the copy path from the COLORS
/// card always includes `#`, so the common case is unambiguous, and the
/// worst case is a wrong axis, never a crash.
enum ColorQuery {
    struct Parsed: Equatable {
        let hexes: [RGB]
        let textRemainder: String
    }

    static func parse(_ raw: String) -> Parsed {
        // Split on whitespace AND commas (the card copies ", "-separated).
        let tokens = raw
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }

        var hexes: [RGB] = []
        var textTokens: [String] = []
        for token in tokens {
            if let rgb = hexRGB(token) {
                hexes.append(rgb)
            } else {
                textTokens.append(token)
            }
        }
        return Parsed(hexes: hexes, textRemainder: textTokens.joined(separator: " "))
    }

    private static let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    private static func hexRGB(_ token: String) -> RGB? {
        var s = token
        if s.hasPrefix("#") { s.removeFirst() }
        guard !s.isEmpty,
              s.unicodeScalars.allSatisfy({ hexDigits.contains($0) }) else { return nil }
        // 3-digit shorthand → 6 (NamedColor.parse decodes 6 only).
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6, let (r, g, b) = NamedColor.parse(s) else { return nil }
        return RGB(r: r, g: g, b: b)
    }
}

/// Decides whether a file's palette satisfies a color query, and scores how
/// closely — the matching + ranking core for the color search path.
enum PaletteMatch {
    /// AND semantics: a file matches iff EACH query color has some palette
    /// color within `threshold`. Mirrors the multi-tag filter's AND, and is
    /// what "find images with this palette" means. An empty palette never
    /// matches (a not-yet-analyzed / non-image file has no color to match).
    static func matches(query: [LabColor], palette: [LabColor], threshold: Double) -> Bool {
        guard !palette.isEmpty else { return false }
        return query.allSatisfy { q in
            palette.contains { ColorDistance.deltaE(q, $0) <= threshold }
        }
    }

    /// Aggregate closeness for ranking a color-only query (lower = closer):
    /// the sum over query colors of the nearest palette ΔE. Empty palette
    /// scores `.infinity` so it sorts last.
    static func score(query: [LabColor], palette: [LabColor]) -> Double {
        guard !palette.isEmpty else { return .infinity }
        return query.reduce(0.0) { acc, q in
            let nearest = palette.map { ColorDistance.deltaE(q, $0) }.min() ?? .infinity
            return acc + nearest
        }
    }
}
