//
//  SocialPreset.swift
//  Muse
//
//  Export/Social/ is platform-neutral — Foundation only here (this file is pure
//  data). The table below is the spec's platform table verbatim and is pinned
//  entry-by-entry by SocialPresetTests, so a changed number is always a
//  deliberate constant edit and never a silent drift.
//
//  Notes bound to the table:
//  · The IG family's byte target is 800 KB (the tighter of the two stated
//    bounds) — hand Instagram a finished sRGB JPEG at exactly 1080 wide so its
//    own encoder has nothing left to do.
//  · Glass and Flickr/500px are photography platforms: EXIF defaults ON there
//    (Glass literally displays the gear info), OFF everywhere else.
//  · The never-upscale floor is GLOBAL (SocialRender), not a per-preset minimum.
//  · `warningKey` strings are advisory. They never block an export.
//  · X carries no advisory because its five hard invariants apply instead.
//

import Foundation

struct SocialPreset: Identifiable, Equatable {
    enum Kind: Equatable {
        case fixed(width: Int, height: Int)   // aspect-mismatch → the crop step applies
        case longEdge(Int)                    // downscale-only; no crop step
        case original                         // no resize at all
    }
    enum SharpenLevel { case none, light, standard }

    let id: String            // stable ("ig-feed-portrait" …) — used in filenames + prefs
    let nameKey: String       // localization key; display via String(localized:)
    let kind: Kind
    let quality: Double       // initial JPEG quality (0…1)
    let byteTargetKB: Int?    // nil = no target; the ladder lives in SocialRender
    let sharpen: SharpenLevel
    let exifDefaultOn: Bool   // photography platforms
    let uniformMulti: Bool    // carousel: every selected image, same ratio
    let storySafeZones: Bool  // 250/1920 top+bottom guides in the crop UI
    let warningKey: String?   // localized advisory shown in the card

    static let all: [SocialPreset] = [
        .init(id: "ig-feed-portrait", nameKey: "IG Feed Portrait",
              kind: .fixed(width: 1080, height: 1350), quality: 0.88,
              byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false,
              warningKey: "Keep key content centered — grid previews crop to 3:4."),
        .init(id: "ig-grid", nameKey: "IG Grid-Optimized",
              kind: .fixed(width: 1080, height: 1440), quality: 0.88,
              byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false,
              warningKey: "The feed crops this to 4:5 — grid tiles show the full 3:4."),
        .init(id: "ig-square", nameKey: "IG Square",
              kind: .fixed(width: 1080, height: 1080), quality: 0.88,
              byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false, warningKey: nil),
        .init(id: "ig-landscape", nameKey: "IG Landscape",
              kind: .fixed(width: 1080, height: 566), quality: 0.88,
              byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false, warningKey: nil),
        .init(id: "ig-story", nameKey: "IG / Threads Story & Reel",
              kind: .fixed(width: 1080, height: 1920), quality: 0.88,
              byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: true, warningKey: nil),
        .init(id: "ig-carousel", nameKey: "IG Carousel",
              kind: .fixed(width: 1080, height: 1350), quality: 0.88,
              byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: true, storySafeZones: false,
              warningKey: "The first slide locks the ratio — every slide exports at 4:5."),
        .init(id: "threads", nameKey: "Threads",
              kind: .fixed(width: 1080, height: 1350), quality: 0.88,
              byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false, warningKey: nil),
        .init(id: "x", nameKey: "X",
              kind: .longEdge(4096), quality: 0.90,
              byteTargetKB: nil, sharpen: .light, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false,
              warningKey: nil),        // SocialRender's X invariants apply instead
        .init(id: "facebook", nameKey: "Facebook",
              kind: .longEdge(2048), quality: 0.85,
              byteTargetKB: 1000, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false, warningKey: nil),
        .init(id: "pinterest", nameKey: "Pinterest",
              kind: .fixed(width: 1000, height: 1500), quality: 0.90,
              byteTargetKB: nil, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false, warningKey: nil),
        .init(id: "flickr", nameKey: "Flickr / 500px",
              kind: .original, quality: 0.95,
              byteTargetKB: nil, sharpen: .none, exifDefaultOn: true,
              uniformMulti: false, storySafeZones: false, warningKey: nil),
        .init(id: "glass", nameKey: "Glass",
              kind: .longEdge(4096), quality: 0.92,
              byteTargetKB: nil, sharpen: .light, exifDefaultOn: true,
              uniformMulti: false, storySafeZones: false, warningKey: nil),
    ]

    static func preset(id: String) -> SocialPreset? { all.first { $0.id == id } }

    /// Fixed-dimension presets are the only ones with an aspect to fit into, so
    /// they're the only ones that get a crop step / fit-mode control.
    var isFixed: Bool { if case .fixed = kind { return true }; return false }

    var targetAspect: CGFloat? {
        if case .fixed(let w, let h) = kind { return CGFloat(w) / CGFloat(h) }
        return nil
    }
}
