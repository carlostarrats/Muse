//
//  SelectionStyle.swift
//  Muse
//
//  Pure decision for the grid selection ring/tint color. Chosen from the
//  app background mood so the ring always stands out: blue on neutral
//  backgrounds, black or white on colorful ones (whichever clears WCAG AA).
//  See docs/superpowers/specs/2026-06-17-grid-selection-redesign-design.md.
//

import Foundation

enum SelectionAccent: Equatable {
    case systemBlue   // neutral background → system accent (blue) ring + tint
    case black        // colorful background, black gives more contrast
    case white        // colorful background, white gives more contrast
}

enum SelectionStyle {
    /// A Custom mood with saturation at/above this counts as "colorful";
    /// below it — and every Light/Dark/Auto mood — is neutral → blue.
    static let colorfulSaturationThreshold = 0.20

    /// The ring/tint color family for a given app background color.
    static func accent(forBackground rgb: MoodRGB) -> SelectionAccent {
        if saturation(rgb) < colorfulSaturationThreshold { return .systemBlue }
        let bg = relativeLuminance(rgb)
        // Pick whichever of white/black has the higher contrast against the
        // background. The max of the two always clears AA (4.5:1) for any
        // saturated color, so the ring is never lost into the background.
        return contrast(1.0, bg) >= contrast(bg, 0.0) ? .white : .black
    }

    /// HSB saturation: (max - min) / max, 0 when the color is black.
    static func saturation(_ rgb: MoodRGB) -> Double {
        let hi = max(rgb.r, max(rgb.g, rgb.b))
        let lo = min(rgb.r, min(rgb.g, rgb.b))
        return hi <= 0 ? 0 : (hi - lo) / hi
    }

    /// WCAG relative luminance (sRGB channels linearized).
    static func relativeLuminance(_ rgb: MoodRGB) -> Double {
        func lin(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(rgb.r) + 0.7152 * lin(rgb.g) + 0.0722 * lin(rgb.b)
    }

    /// WCAG contrast ratio between two relative luminances.
    static func contrast(_ a: Double, _ b: Double) -> Double {
        let hi = max(a, b), lo = min(a, b)
        return (hi + 0.05) / (lo + 0.05)
    }
}
