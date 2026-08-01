//
//  ImageLayout.swift
//  Muse
//
//  How images are laid out on every grid. Three modes, all of which draw each
//  image at its own natural shape — none crops, none letterboxes:
//
//    Columns — vertical columns, ragged bottom (the classic masonry pack)
//    Rows    — every row one height, widths natural, rows justified to the width
//    Grid    — one square slot per image, the image fitted inside it
//
//  Global — applies on all-tags, a single tag, and inside a collection.
//
//  This replaced a masonry default plus ten fixed aspect ratios (1:1, 9:16,
//  4:5, …). The ratios picked a CARD shape, not an image shape: the visible
//  slab around a fitted image is what made them look imposed, and with the slab
//  gone they had nothing left to express. The middle eight were also
//  indistinguishable in practice (~7% steps in rendered height).
//

import CoreGraphics

enum ImageLayout: String, CaseIterable, Identifiable {
    case columns
    case rows
    case grid

    var id: String { rawValue }

    /// Label on the modal tile.
    var displayName: String {
        switch self {
        case .columns: return String(localized: "Columns")
        case .rows:    return String(localized: "Rows")
        case .grid:    return String(localized: "Grid")
        }
    }

    /// A single uniform tile aspect (height ÷ width) when the layout imposes
    /// one, else `nil`. Only Grid does — square slots, which `MasonryGeometry`
    /// packs into an exact aligned row-major grid when every aspect is equal.
    ///
    /// Also read as "is this a uniform lattice?" by the hero parting ripple
    /// (which damps its amplitude on one) and by the PDF exporter.
    /// `nonisolated`: read by the off-main PDF exporter's page layout.
    nonisolated var aspect: CGFloat? {
        switch self {
        case .columns, .rows: return nil
        case .grid:           return 1
        }
    }

    /// Which preview graphic the modal draws for this layout.
    var iconKind: LayoutIconKind {
        switch self {
        case .columns: return .columns
        case .rows:    return .rows
        case .grid:    return .grid
        }
    }

    /// Parse a persisted raw value.
    ///
    /// Migration matters here: `"masonry"` and the ten `r*` ratio raws are live
    /// on users' disks. Falling through to the default would silently drop a
    /// ratio user into Columns — a visibly different layout — so map them:
    /// masonry is Columns under a new name, and a fixed ratio is closest to
    /// Grid (an aligned lattice of same-size slots).
    static func resolve(_ raw: String?) -> ImageLayout {
        guard let raw else { return .columns }
        if let known = ImageLayout(rawValue: raw) { return known }
        if raw == "masonry" { return .columns }
        if raw.first == "r", raw.dropFirst().contains("x") { return .grid }
        return .columns
    }
}

/// The three preview graphics in the layout modal.
enum LayoutIconKind {
    case columns, rows, grid
}
