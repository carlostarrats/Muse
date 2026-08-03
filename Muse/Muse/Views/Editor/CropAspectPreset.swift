//
//  CropAspectPreset.swift
//  Muse
//
//  The crop menu's rows. Each names BOTH a destination and a ratio, at equal
//  weight — a photographer scans for "3:2", someone posting scans for
//  "Story & Reel", and neither should have to decode the other. That is why
//  there is no bare "16:9" row and no bare "Widescreen" row either.
//
//  The ratio is stored as two INTEGERS rather than a Double so the label can be
//  printed exactly and so the orientation toggle can swap it honestly: flipping
//  4:3 has to read "3:4", not "4:3" with an invisible change of meaning.
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
    /// Width and height as the preset is normally written. Nil for the two
    /// rows that are modes rather than shapes.
    private let num: Int?
    private let den: Int?

    var ratio: Double? {
        guard let num, let den, den != 0 else { return nil }
        return Double(num) / Double(den)
    }

    /// The orientation toggle swaps width and height, so each shape is ONE row
    /// rather than two — the menu stays scannable, and the user makes one
    /// decision about shape and a separate one about which way up.
    func ratio(portrait: Bool) -> Double? {
        guard let num, let den, num != 0, den != 0 else { return nil }
        return portrait ? Double(den) / Double(num) : Double(num) / Double(den)
    }

    /// Square, Original and Freeform have no orientation to swap, so the
    /// button disables rather than sitting there doing nothing.
    var supportsOrientation: Bool {
        guard let num, let den else { return false }
        return num != den
    }

    /// The ratio as the user reads it — and it FOLLOWS the orientation toggle,
    /// so pressing Portrait on 4:3 shows "3:4". Showing the unswapped ratio
    /// made the toggle look like it had done nothing.
    func ratioLabel(portrait: Bool = false) -> String {
        guard let num, let den else { return "" }
        let (a, b) = portrait ? (den, num) : (num, den)
        return "\(a):\(b)"
    }

    /// Purpose and value in one string, for the menu row.
    func menuTitle(portrait: Bool = false) -> String {
        let ratio = ratioLabel(portrait: portrait)
        return ratio.isEmpty ? label : "\(label)   \(ratio)"
    }

    private static func socialName(_ presetID: String, fallback: String) -> String {
        guard let key = SocialPreset.preset(id: presetID)?.nameKey else { return fallback }
        return String(localized: String.LocalizationValue(key))
    }

    static let original = CropAspectPreset(
        id: "original", label: String(localized: "Original"), num: nil, den: nil)
    static let freeform = CropAspectPreset(
        id: "freeform", label: String(localized: "Freeform"), num: nil, den: nil)
    static let square = CropAspectPreset(
        id: "square", label: String(localized: "Square"), num: 1, den: 1)
    static let igPost = CropAspectPreset(
        id: "ig-post",
        label: socialName("instagram", fallback: String(localized: "Instagram Post")),
        num: 4, den: 5)
    static let story = CropAspectPreset(
        id: "ig-story",
        label: socialName("ig-story", fallback: String(localized: "Story & Reel")),
        num: 9, den: 16)
    static let print4x6 = CropAspectPreset(
        id: "print-4x6", label: String(localized: "Print 4×6"), num: 3, den: 2)
    static let print8x10 = CropAspectPreset(
        id: "print-8x10", label: String(localized: "Print 8×10"), num: 5, den: 4)
    static let cameraDefault = CropAspectPreset(
        id: "camera-default", label: String(localized: "Camera Default"), num: 4, den: 3)
    static let widescreen = CropAspectPreset(
        id: "widescreen", label: String(localized: "Video / Widescreen"), num: 16, den: 9)

    /// Original and Freeform sit above the divider because they are MODES, not
    /// shapes. Nine rows is about the ceiling before a menu stops being
    /// scannable, so a new one should replace rather than extend.
    static let modes: [CropAspectPreset] = [.original, .freeform]
    static let shapes: [CropAspectPreset] = [
        .square, .igPost, .story, .print4x6, .print8x10, .cameraDefault, .widescreen,
    ]
    static let all: [CropAspectPreset] = modes + shapes
}
