//
//  GridFilter.swift
//  Muse
//
//  Pure, unit-testable faceted filter for the grid: narrow the visible tiles by
//  kind. Images break down into format leaves (JPEG/PNG/HEIC/…); every other
//  kind stays a single leaf. The stored model is one flat `Set<KindFacet>` of
//  LEAF facets with an "empty == all" sentinel — the "Images" parent is purely a
//  UI grouping (see GridFilterPopover), not a stored facet. Mirrors the shape of
//  ImageLayout / TileBackground — a value type + matcher persisted via
//  AppSettings and mirrored on AppState. `matches` takes raw inputs (kind + file
//  extension); the source of those values (FileNode) is an implementation detail
//  of the caller. NOT a sort — it removes non-matching files from whichever set
//  is active (folder / collection / tag / search). (Date and size filtering were
//  removed — sort-by-date and sort-by-size cover those needs; feat/next-48.)
//

import Foundation

/// Leaf facets the filter narrows by. Image kinds expand into format leaves
/// (JPEG/PNG/HEIC/TIFF/GIF/WebP/RAW/PSD/SVG + an `imageOther` catch-all so no
/// image format is ever unreachable); every non-image kind is a single leaf.
/// `folder` is its own leaf so the one-level browse view's subfolder cards can
/// be toggled on/off. (feat/next-48 replaced the old coarse `.image` facet.)
enum KindFacet: String, CaseIterable, Identifiable, Codable {
    // Image-format leaves (grouped under the "Images" UI parent).
    case jpeg, png, heic, tiff, gif, webp, raw, psd, svg, imageOther
    // Non-image kinds (each a single leaf). `xmp` exists so RAW-workflow
    // folders (an .xmp sidecar beside every photo) can hide the sidecar cards
    // without hiding real documents — user choice, nothing removed
    // (feat/next-125, alongside the keywords & ratings import).
    case video, pdf, document, audio, xmp, folder, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jpeg:       return String(localized: "JPEG")
        case .png:        return String(localized: "PNG")
        case .heic:       return String(localized: "HEIC")
        case .tiff:       return String(localized: "TIFF")
        case .gif:        return String(localized: "GIF")
        case .webp:       return String(localized: "WebP")
        case .raw:        return String(localized: "RAW")
        case .psd:        return String(localized: "PSD")
        case .svg:        return String(localized: "SVG")
        case .imageOther: return String(localized: "Other")
        case .video:      return String(localized: "Videos")
        case .pdf:        return String(localized: "PDFs")
        case .document:   return String(localized: "Documents")
        case .audio:      return String(localized: "Audio")
        case .xmp:        return String(localized: "XMP Sidecars")
        case .folder:     return String(localized: "Folders")
        case .other:      return String(localized: "Other")
        }
    }

    /// The image-format leaves, in display order, grouped under the UI "Images"
    /// parent. Order also drives the indented checkbox list.
    static let imageLeaves: [KindFacet] = [
        .jpeg, .png, .heic, .tiff, .gif, .webp, .raw, .psd, .svg, .imageOther
    ]

    /// The non-image kind leaves, in display order (the top-level rows below the
    /// "Images" group heading).
    static let topLevelKinds: [KindFacet] = [.video, .pdf, .document, .audio, .xmp, .folder, .other]

    /// Resolve a file to the single leaf that controls it. Pure — the extension
    /// comes from the caller's `FileNode.url`; no IO. An image-kind file whose
    /// format isn't named maps to `imageOther` so it's always reachable.
    static func leaf(kind: AssetKind, ext: String) -> KindFacet {
        // .xmp sidecars have no dedicated AssetKind (they classify as text or
        // unknown depending on the system's UTType data), so route by
        // extension before the kind switch.
        if ext.lowercased() == "xmp" { return .xmp }
        switch kind {
        case .raw: return .raw
        case .psd: return .psd
        case .svg: return .svg
        case .image:
            switch ext.lowercased() {
            case "jpg", "jpeg":  return .jpeg
            case "png":          return .png
            case "heic", "heif": return .heic
            case "tif", "tiff":  return .tiff
            case "gif":          return .gif
            case "webp":         return .webp
            default:             return .imageOther
            }
        case .video:                           return .video
        case .pdf:                             return .pdf
        case .text, .markdown, .code, .office: return .document
        case .audio:                           return .audio
        case .folder:                          return .folder
        case .model3d, .font, .archive, .unknown:
            return .other
        }
    }
}

/// Tri-state of the over-arching "Images" checkbox, derived from how many image
/// leaves the filter currently includes.
enum ParentCheckState: Equatable {
    case on    // all image leaves included
    case mixed // some included
    case off   // none included
}

struct GridFilter: Equatable, Codable {
    /// Empty = no kind constraint (all leaves shown). Otherwise the exact set of
    /// leaves to show.
    var kinds: Set<KindFacet>

    static let none = GridFilter(kinds: [])

    private static let allLeaves = Set(KindFacet.allCases)

    /// True when any facet constrains the result.
    var isActive: Bool { !kinds.isEmpty }

    /// Pure predicate. The extension comes from the caller's `FileNode.url`.
    func matches(kind: AssetKind, ext: String) -> Bool {
        guard !kinds.isEmpty else { return true }   // empty = all
        return kinds.contains(KindFacet.leaf(kind: kind, ext: ext))
    }

    /// The effective leaf set, expanding the "empty == all" sentinel.
    private var effective: Set<KindFacet> {
        kinds.isEmpty ? Self.allLeaves : kinds
    }

    /// Collapse a working set back to the sentinel: a full OR empty set both mean
    /// "all shown" (`.none`), never "show nothing".
    private static func collapse(_ set: Set<KindFacet>) -> GridFilter {
        (set == allLeaves || set.isEmpty) ? .none : GridFilter(kinds: set)
    }

    /// Flip a single leaf on/off (every checkbox in the popover), honoring the
    /// empty-as-all sentinel.
    func toggling(_ facet: KindFacet) -> GridFilter {
        var set = effective
        if set.contains(facet) { set.remove(facet) } else { set.insert(facet) }
        return Self.collapse(set)
    }

    /// State of the over-arching "Images" checkbox.
    var imageParentState: ParentCheckState {
        let set = effective
        let present = KindFacet.imageLeaves.filter { set.contains($0) }.count
        if present == 0 { return .off }
        if present == KindFacet.imageLeaves.count { return .on }
        return .mixed
    }

    /// Toggle the whole image group: if every image leaf is currently included,
    /// remove them all; otherwise add them all.
    func togglingImageGroup() -> GridFilter {
        var set = effective
        let allImagesOn = KindFacet.imageLeaves.allSatisfy { set.contains($0) }
        if allImagesOn {
            KindFacet.imageLeaves.forEach { set.remove($0) }
        } else {
            KindFacet.imageLeaves.forEach { set.insert($0) }
        }
        return Self.collapse(set)
    }

    /// Decode a persisted JSON string, defaulting to `.none` when missing/invalid.
    /// A filter saved before feat/next-48 holds the old coarse `"image"` leaf
    /// (and possibly date/size keys); the unknown enum case fails to decode, so
    /// it falls back to `.none` (all shown) — acceptable for transient view state.
    static func resolve(_ raw: String?) -> GridFilter {
        guard let raw, let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(GridFilter.self, from: data)
        else { return .none }
        return decoded
    }
}
