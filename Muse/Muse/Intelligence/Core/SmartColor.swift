//
//  SmartColor.swift
//  Muse
//
//  Named colors for the smart-collection color rule. People think "blue," not
//  "#3a7bd5" — so the rule picks a named swatch, which maps to one
//  representative sRGB point matched perceptually against each file's palette
//  (the same PaletteMatch / CIEDE2000 path the hex color-search uses). The
//  token is the stored identity (never the display name); RGB is resolution.
//

import Foundation

/// The curated named-color spectrum offered by the color rule. Token strings
/// are the persisted identity (in `SmartRule.color(.name(token))`), so treat
/// them as frozen — renaming one orphans saved rules.
enum SmartColor {
    /// (token, representative sRGB 0…1), in spectrum order for the picker.
    static let swatches: [(token: String, rgb: RGB)] = [
        ("red",    RGB(r: 0.937, g: 0.267, b: 0.267)),
        ("orange", RGB(r: 0.976, g: 0.451, b: 0.086)),
        ("yellow", RGB(r: 0.918, g: 0.702, b: 0.031)),
        ("green",  RGB(r: 0.133, g: 0.773, b: 0.369)),
        ("teal",   RGB(r: 0.078, g: 0.722, b: 0.651)),
        ("cyan",   RGB(r: 0.024, g: 0.714, b: 0.831)),
        ("blue",   RGB(r: 0.231, g: 0.510, b: 0.965)),
        ("navy",   RGB(r: 0.114, g: 0.306, b: 0.847)),
        ("purple", RGB(r: 0.659, g: 0.333, b: 0.969)),
        ("pink",   RGB(r: 0.925, g: 0.286, b: 0.600)),
        ("brown",  RGB(r: 0.545, g: 0.353, b: 0.169)),
        ("black",  RGB(r: 0.080, g: 0.080, b: 0.080)),
        ("gray",   RGB(r: 0.500, g: 0.500, b: 0.500)),
        ("white",  RGB(r: 0.950, g: 0.950, b: 0.950)),
    ]

    /// All tokens in picker order.
    static let tokens: [String] = swatches.map(\.token)

    /// Representative sRGB for a token, or nil for an unknown one.
    static func rgb(for token: String) -> RGB? {
        swatches.first { $0.token == token }?.rgb
    }
}
