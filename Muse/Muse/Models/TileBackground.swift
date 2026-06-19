//
//  TileBackground.swift
//  Muse
//
//  The backdrop drawn behind grid content — the letterbox around aspect-fit
//  images and the background of non-image file cards. Decoupled from the app
//  mood: None (transparent), Auto (follows the mood tile color — the default),
//  and three fixed neutral densities (Light / Dark Grey / Black) for separating
//  images that would otherwise blend into the backdrop. Global; also carried
//  into the collection PDF export. `backdropRGB` is the single resolver.
//

import SwiftUI

enum TileBackground: String, CaseIterable, Identifiable {
    case none, auto, light, darkGrey, black

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:     return "None"
        case .auto:     return "Auto"
        case .light:    return "Light"
        case .darkGrey: return "Dark Grey"
        case .black:    return "Black"
        }
    }

    /// Resolved backdrop color, or `nil` for None (transparent — no fill drawn).
    /// Auto follows the mood's tile color; the static cases are fixed neutrals
    /// that ignore the mood.
    func backdropRGB(for mood: MoodPalette) -> MoodRGB? {
        switch self {
        case .none:     return nil
        case .auto:     return mood.tileRGB
        case .light:    return MoodRGB(r: 0.980, g: 0.980, b: 0.980)
        case .darkGrey: return MoodRGB(r: 0.333, g: 0.333, b: 0.333)
        case .black:    return MoodRGB(r: 0.051, g: 0.051, b: 0.051)
        }
    }

    /// SwiftUI fill for an on-screen grid tile. None → `.clear` (transparent).
    func fill(for mood: MoodPalette) -> Color {
        backdropRGB(for: mood)?.color ?? .clear
    }

    /// Parse a persisted raw value, defaulting to Auto when missing/unknown.
    static func resolve(_ raw: String?) -> TileBackground {
        raw.flatMap(TileBackground.init(rawValue:)) ?? .auto
    }
}
