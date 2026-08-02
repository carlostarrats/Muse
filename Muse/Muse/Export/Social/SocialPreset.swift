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

    /// FOUR presets, cut down from twelve on 2026-08-02 (owner review).
    ///
    /// What went, and why it wasn't a loss:
    /// · **Threads** carried numbers IDENTICAL to the IG feed row — 1080×1350,
    ///   q0.88, 800 KB. It was a separate entry for completeness, not because
    ///   the platform differs. Instagram covers it.
    /// · **IG Grid / Square / Landscape / Carousel** were four ways to crop for
    ///   one destination. Instagram accepts anything from 1.91:1 to 4:5, so a
    ///   plain 1080 long-edge hands it a correctly-sized file at the photo's
    ///   OWN aspect and no crop step is needed at all — which is what a
    ///   photographer wants, and strictly more capable than picking a box.
    /// · **Pinterest, Flickr/500px, Glass** — real platforms, but not ones this
    ///   app's users asked for. Any of them is served by the Format family now
    ///   (JPEG at whatever size), which is the general answer.
    ///
    /// Story/Reel stays FIXED because it genuinely is a fixed frame with
    /// platform chrome over it — that's what the safe zones exist for.
    static let all: [SocialPreset] = [
        .init(id: "instagram", nameKey: "Instagram",
              kind: .longEdge(1080), quality: 0.88,
              byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false, warningKey: nil),
        .init(id: "ig-story", nameKey: "Instagram Story & Reel",
              kind: .fixed(width: 1080, height: 1920), quality: 0.88,
              byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: true, warningKey: nil),
        .init(id: "x", nameKey: "X",
              kind: .longEdge(4096), quality: 0.90,
              byteTargetKB: nil, sharpen: .light, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false,
              warningKey: nil),        // SocialRender's X invariants apply instead
        .init(id: "facebook", nameKey: "Facebook",
              kind: .longEdge(2048), quality: 0.85,
              byteTargetKB: 1000, sharpen: .standard, exifDefaultOn: false,
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
