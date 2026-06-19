//
//  Mood.swift
//  Muse
//
//  Background moods: White, Dark (the original Ink), Auto (white by
//  day, dark by night), and Custom — a user-picked HSB color via the
//  mood popover's inline gradient sliders (design after kieranb662's
//  SwiftUI-Color-Kit; implemented natively, no dependency).
//

import SwiftUI

struct MoodRGB: Equatable {
    var r: Double
    var g: Double
    var b: Double
    var color: Color { Color(red: r, green: g, blue: b) }
    /// sRGB CGColor — matches `color`'s sRGB space so an exported PDF backdrop
    /// renders the same hue as the on-screen tile.
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

struct MoodPalette: Equatable {
    var backgroundRGB: MoodRGB
    var tileRGB: MoodRGB
    var scheme: ColorScheme

    var background: Color { backgroundRGB.color }
    var tileFill: Color { tileRGB.color }
}

enum Mood: String, CaseIterable, Identifiable {
    case paper, ink, auto, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paper:  return "Light"
        case .ink:    return "Dark"
        case .auto:   return "Auto"
        case .custom: return "Custom"
        }
    }

    /// The guaranteed fallback palette (Dark/Ink) — also the Graph scene's
    /// fixed background.
    static let fallbackPalette = MoodPalette(
        backgroundRGB: MoodRGB(r: 0.066, g: 0.066, b: 0.078),
        tileRGB: MoodRGB(r: 0.118, g: 0.118, b: 0.133),
        scheme: .dark)

    /// Clean near-white.
    static let paperPalette = MoodPalette(
        backgroundRGB: MoodRGB(r: 0.965, g: 0.962, b: 0.955),
        tileRGB: MoodRGB(r: 0.905, g: 0.901, b: 0.892),
        scheme: .light)

    /// Auto: white during the day, dark at night.
    static func isDaytime(_ date: Date = Date()) -> Bool {
        (7..<19).contains(Calendar.current.component(.hour, from: date))
    }

    /// Palette for the Custom mood. Tile nudges brightness toward contrast;
    /// the scheme flips on perceived luminance so text stays readable at
    /// any picked color.
    static func customPalette(hue: Double, saturation: Double,
                              brightness: Double) -> MoodPalette {
        let bg = hsbToRGB(hue * 360, saturation, brightness)
        let tileB = brightness > 0.5 ? max(0, brightness - 0.07)
                                     : min(1, brightness + 0.07)
        let tile = hsbToRGB(hue * 360, saturation, tileB)
        let luminance = 0.2126 * bg.0 + 0.7152 * bg.1 + 0.0722 * bg.2
        return MoodPalette(
            backgroundRGB: MoodRGB(r: bg.0, g: bg.1, b: bg.2),
            tileRGB: MoodRGB(r: tile.0, g: tile.1, b: tile.2),
            scheme: luminance > 0.55 ? .light : .dark)
    }

    // MARK: - Persistence

    private static let defaultsKey = "muse.mood"

    /// Old rawValues (navy/blush) decode to nil and fall back to Dark.
    static func load(from defaults: UserDefaults = .standard) -> Mood {
        defaults.string(forKey: defaultsKey).flatMap(Mood.init(rawValue:)) ?? .ink
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Mood.defaultsKey)
    }

    // MARK: - HSB math (pure; h in degrees 0..<360, s/v in 0...1)

    static func hsbToRGB(_ h: Double, _ s: Double, _ v: Double)
        -> (Double, Double, Double) {
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60:  (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default:     (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }
}
