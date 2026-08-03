//
//  CropAspectPreset.swift
//  Muse
//
//  The crop menu's rows. Each names BOTH a destination and a ratio, at equal
//  weight — a photographer scans for "3:2", someone posting scans for
//  "Story & Reel", and neither should have to decode the other. That is why
//  there is no bare "16:9" row and no bare "Widescreen" row either.
//
//  The two social rows read their DISPLAY NAME from `SocialPreset` so the crop
//  menu and the export card cannot drift apart. The NAME is shared, not the
//  geometry: `SocialPreset`'s four remaining entries are deliberately mostly
//  `longEdge` with no aspect at all — its own comment explains that a plain
//  1080 long edge "hands it a correctly-sized file at the photo's OWN aspect
//  and no crop step is needed", which is why twelve presets became four.
//  Coupling this menu to that table would fight the reasoning behind the cut.
//

import Foundation

struct CropAspectPreset: Identifiable, Equatable {
    let id: String
    let label: String
    /// Landscape orientation, width ÷ height. Nil = no fixed ratio.
    private let baseRatio: Double?

    var ratio: Double? { baseRatio }

    /// The portrait toggle swaps width and height, so 16:9 and 9:16 are ONE
    /// row rather than two — the menu stays scannable and the user makes one
    /// decision about shape and a separate one about orientation.
    func ratio(portrait: Bool) -> Double? {
        guard let baseRatio, baseRatio > 0 else { return nil }
        return portrait ? 1 / baseRatio : baseRatio
    }

    /// Square, Original and Freeform have no orientation to swap, so the
    /// button disables rather than sitting there doing nothing.
    var supportsOrientation: Bool {
        guard let baseRatio else { return false }
        return abs(baseRatio - 1) > 1e-9
    }

    /// The ratio as the user reads it, shown beside the label at the same
    /// weight. Empty for the two rows that are modes rather than shapes.
    var ratioLabel: String {
        switch id {
        case "original", "freeform": ""
        case "square": "1:1"
        case "ig-post": "4:5"
        case "ig-story": "9:16"
        case "print-4x6": "3:2"
        case "print-8x10": "5:4"
        case "camera-default": "4:3"
        default: "16:9"
        }
    }

    /// Purpose and value in one string, for the menu row.
    var menuTitle: String {
        ratioLabel.isEmpty ? label : "\(label)   \(ratioLabel)"
    }

    private static func socialName(_ presetID: String, fallback: String) -> String {
        guard let key = SocialPreset.preset(id: presetID)?.nameKey else { return fallback }
        return String(localized: String.LocalizationValue(key))
    }

    static let original = CropAspectPreset(
        id: "original", label: String(localized: "Original"), baseRatio: nil)
    static let freeform = CropAspectPreset(
        id: "freeform", label: String(localized: "Freeform"), baseRatio: nil)
    static let square = CropAspectPreset(
        id: "square", label: String(localized: "Square"), baseRatio: 1)
    static let igPost = CropAspectPreset(
        id: "ig-post",
        label: socialName("instagram", fallback: String(localized: "Instagram Post")),
        baseRatio: 4.0 / 5.0)
    static let story = CropAspectPreset(
        id: "ig-story",
        label: socialName("ig-story", fallback: String(localized: "Story & Reel")),
        baseRatio: 9.0 / 16.0)
    static let print4x6 = CropAspectPreset(
        id: "print-4x6", label: String(localized: "Print 4×6"), baseRatio: 3.0 / 2.0)
    static let print8x10 = CropAspectPreset(
        id: "print-8x10", label: String(localized: "Print 8×10"), baseRatio: 5.0 / 4.0)
    static let cameraDefault = CropAspectPreset(
        id: "camera-default", label: String(localized: "Camera Default"), baseRatio: 4.0 / 3.0)
    static let widescreen = CropAspectPreset(
        id: "widescreen", label: String(localized: "Video / Widescreen"), baseRatio: 16.0 / 9.0)

    /// Original and Freeform sit above the divider because they are MODES, not
    /// shapes. Nine rows is about the ceiling before a menu stops being
    /// scannable, so a new one should replace rather than extend.
    static let modes: [CropAspectPreset] = [.original, .freeform]
    static let shapes: [CropAspectPreset] = [
        .square, .igPost, .story, .print4x6, .print8x10, .cameraDefault, .widescreen,
    ]
    static let all: [CropAspectPreset] = modes + shapes
}
