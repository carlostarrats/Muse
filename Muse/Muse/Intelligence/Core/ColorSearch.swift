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
    /// 25⁷, the fixed CIEDE2000 chroma-weighting constant. Hoisted so the
    /// hot deltaE loop (thousands of calls per search) doesn't re-`pow` it.
    private static let pow25_7: Double = pow(25.0, 7)

    /// CIEDE2000 — the perceptually-accurate ΔE. Plain Euclidean LAB (CIE76)
    /// was tried first but is too non-uniform, especially in blues and light
    /// neutrals: against a real 2200-image library it couldn't separate a
    /// genuine blue-family match from noise without also matching greens/reds
    /// (a light-grey query color matched ~90% of images at any threshold that
    /// still caught real blues). CIEDE2000 gives a clean precision curve; the
    /// spec named it as the drop-in upgrade behind this same signature.
    static func deltaE(_ x: LabColor, _ y: LabColor) -> Double {
        let kL = 1.0, kC = 1.0, kH = 1.0
        let c1 = (x.a * x.a + x.b * x.b).squareRoot()
        let c2 = (y.a * y.a + y.b * y.b).squareRoot()
        let cBar = (c1 + c2) / 2
        let cBar7 = pow(cBar, 7)
        let g = cBar > 0 ? 0.5 * (1 - (cBar7 / (cBar7 + pow25_7)).squareRoot()) : 0.5

        let a1p = (1 + g) * x.a
        let a2p = (1 + g) * y.a
        let c1p = (a1p * a1p + x.b * x.b).squareRoot()
        let c2p = (a2p * a2p + y.b * y.b).squareRoot()

        func hp(_ ap: Double, _ b: Double) -> Double {
            if ap == 0 && b == 0 { return 0 }
            let h = atan2(b, ap) * 180 / .pi
            return h < 0 ? h + 360 : h
        }
        let h1p = hp(a1p, x.b)
        let h2p = hp(a2p, y.b)

        let dLp = y.L - x.L
        let dCp = c2p - c1p
        var dhp: Double
        if c1p * c2p == 0 { dhp = 0 }
        else if abs(h2p - h1p) <= 180 { dhp = h2p - h1p }
        else if h2p - h1p > 180 { dhp = h2p - h1p - 360 }
        else { dhp = h2p - h1p + 360 }
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(dhp * .pi / 180 / 2)

        let lBarP = (x.L + y.L) / 2
        let cBarP = (c1p + c2p) / 2
        var hBarP: Double
        if c1p * c2p == 0 { hBarP = h1p + h2p }
        else if abs(h1p - h2p) <= 180 { hBarP = (h1p + h2p) / 2 }
        else if h1p + h2p < 360 { hBarP = (h1p + h2p + 360) / 2 }
        else { hBarP = (h1p + h2p - 360) / 2 }

        func deg(_ d: Double) -> Double { d * .pi / 180 }
        let t = 1 - 0.17 * cos(deg(hBarP - 30)) + 0.24 * cos(deg(2 * hBarP))
                + 0.32 * cos(deg(3 * hBarP + 6)) - 0.20 * cos(deg(4 * hBarP - 63))
        let dRo = 30 * exp(-pow((hBarP - 275) / 25, 2))
        let cBarP7 = pow(cBarP, 7)
        let rc = cBarP > 0 ? 2 * (cBarP7 / (cBarP7 + pow25_7)).squareRoot() : 0
        let sL = 1 + (0.015 * pow(lBarP - 50, 2)) / (20 + pow(lBarP - 50, 2)).squareRoot()
        let sC = 1 + 0.045 * cBarP
        let sH = 1 + 0.015 * cBarP * t
        let rt = -sin(deg(2 * dRo)) * rc

        let termL = dLp / (kL * sL)
        let termC = dCp / (kC * sC)
        let termH = dHp / (kH * sH)
        return (termL * termL + termC * termC + termH * termH + rt * termC * termH).squareRoot()
    }

    /// "Near" cutoff (ΔE2000). A single internal constant, NOT a user setting.
    /// 15 = "same color family" — tuned against a real library so a pasted
    /// palette matches visibly-similar images without dragging in unrelated
    /// hues. (At 15, obviously-wrong palettes — pure green/red/pink — are
    /// correctly excluded; ~20+ starts to over-match.)
    static let nearThreshold: Double = 15
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
