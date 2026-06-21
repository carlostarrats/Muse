//
//  ImageLayout.swift
//  Muse
//
//  How images are laid out on every grid. Masonry (default) packs each
//  image's natural aspect ratio; the fixed cases give every tile one ratio
//  and letterbox the image inside it (never cropping). Global — applies on
//  all-tags, a single tag, and inside a collection.
//

import CoreGraphics

enum ImageLayout: String, CaseIterable, Identifiable {
    case masonry
    case r1x1, r9x16, r16x9
    case r4x5, r5x4, r6x7, r7x6
    case r2x3, r3x2, r3x4, r4x3

    var id: String { rawValue }

    /// Label on the modal tile; for ratios it's also the size key.
    var displayName: String {
        switch self {
        case .masonry: return String(localized: "Masonry")
        case .r1x1:  return String(localized: "1:1")
        case .r9x16: return String(localized: "9:16")
        case .r16x9: return String(localized: "16:9")
        case .r4x5:  return String(localized: "4:5")
        case .r5x4:  return String(localized: "5:4")
        case .r6x7:  return String(localized: "6:7")
        case .r7x6:  return String(localized: "7:6")
        case .r2x3:  return String(localized: "2:3")
        case .r3x2:  return String(localized: "3:2")
        case .r3x4:  return String(localized: "3:4")
        case .r4x3:  return String(localized: "4:3")
        }
    }

    /// Tile aspect as height ÷ width (MasonryGeometry's convention). `nil` for
    /// masonry, which uses each image's natural ratio. Names are width:height,
    /// so 9:16 → tall (16/9), 16:9 → wide (9/16).
    var aspect: CGFloat? {
        switch self {
        case .masonry: return nil
        case .r1x1:  return 1
        case .r9x16: return 16.0 / 9
        case .r16x9: return 9.0 / 16
        case .r4x5:  return 5.0 / 4
        case .r5x4:  return 4.0 / 5
        case .r6x7:  return 7.0 / 6
        case .r7x6:  return 6.0 / 7
        case .r2x3:  return 3.0 / 2
        case .r3x2:  return 2.0 / 3
        case .r3x4:  return 4.0 / 3
        case .r4x3:  return 3.0 / 4
        }
    }

    /// Which generic preview graphic the modal draws for this layout.
    var iconKind: LayoutIconKind {
        switch self {
        case .masonry: return .mason
        case .r1x1: return .square
        case .r9x16, .r4x5, .r6x7, .r2x3, .r3x4: return .portrait
        case .r16x9, .r5x4, .r7x6, .r3x2, .r4x3: return .landscape
        }
    }

    /// Parse a persisted raw value, defaulting to masonry when missing/unknown.
    static func resolve(_ raw: String?) -> ImageLayout {
        raw.flatMap(ImageLayout.init(rawValue:)) ?? .masonry
    }
}

/// The four generic preview graphics in the layout modal — quick context for
/// the ratio category, not an exact preview.
enum LayoutIconKind {
    case mason, square, portrait, landscape
}
