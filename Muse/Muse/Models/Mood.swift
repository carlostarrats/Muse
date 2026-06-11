//
//  Mood.swift
//  Muse
//
//  Background moods (polish spec §4): Ink (current dark), Paper (the
//  prototyped warm beige), Navy, Blush, and Auto (computed from the
//  dominant colors of the current view's content — see AutoTint).
//  Each named mood is hand-tuned so text/thumbnails/shaders hold up.
//

import SwiftUI

struct MoodRGB: Equatable {
    var r: Double
    var g: Double
    var b: Double
    var color: Color { Color(red: r, green: g, blue: b) }
}

struct MoodPalette: Equatable {
    var backgroundRGB: MoodRGB
    var tileRGB: MoodRGB
    var scheme: ColorScheme

    var background: Color { backgroundRGB.color }
    var tileFill: Color { tileRGB.color }
}

enum Mood: String, CaseIterable, Identifiable {
    case ink, paper, navy, blush, auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ink: return "Ink"
        case .paper: return "Paper"
        case .navy: return "Navy"
        case .blush: return "Blush"
        case .auto: return "Auto"
        }
    }

    /// The guaranteed fallback palette (Ink) — used when Auto has no tint yet.
    static let fallbackPalette = MoodPalette(
        backgroundRGB: MoodRGB(r: 0.066, g: 0.066, b: 0.078),
        tileRGB: MoodRGB(r: 0.118, g: 0.118, b: 0.133),
        scheme: .dark)

    /// nil for .auto — its palette comes from AutoTint at runtime.
    var palette: MoodPalette? {
        switch self {
        case .ink:     // matches the Graph scene's Ink
            return Self.fallbackPalette
        case .paper:   // warm beige, as prototyped (#E6CFB5)
            return MoodPalette(
                backgroundRGB: MoodRGB(r: 0.902, g: 0.812, b: 0.710),
                tileRGB: MoodRGB(r: 0.945, g: 0.882, b: 0.806),
                scheme: .light)
        case .navy:
            return MoodPalette(
                backgroundRGB: MoodRGB(r: 0.051, g: 0.106, b: 0.180),
                tileRGB: MoodRGB(r: 0.090, g: 0.157, b: 0.247),
                scheme: .dark)
        case .blush:   // muted rose
            return MoodPalette(
                backgroundRGB: MoodRGB(r: 0.910, g: 0.827, b: 0.808),
                tileRGB: MoodRGB(r: 0.949, g: 0.886, b: 0.871),
                scheme: .light)
        case .auto:
            return nil
        }
    }

    // MARK: - Persistence

    private static let defaultsKey = "muse.mood"

    static func load(from defaults: UserDefaults = .standard) -> Mood {
        defaults.string(forKey: defaultsKey).flatMap(Mood.init(rawValue:)) ?? .ink
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Mood.defaultsKey)
    }
}
