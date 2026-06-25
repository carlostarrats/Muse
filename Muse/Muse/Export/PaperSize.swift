//
//  PaperSize.swift
//  Muse
//
//  The paper sizes offered by the collection PDF "Save to…" dropdown. Pure
//  value type (no AppKit) so it's unit-testable; `ShareCollectionButton` maps a
//  popup selection to one of these and hands its `.size` to the exporter.
//  Portrait only by design (see the 2026-06-25 paper-size spec). 11×14 is the
//  default — it preserves the original hardcoded page size.
//

import CoreGraphics
import Foundation

enum PaperSize: String, CaseIterable {
    case elevenByFourteen
    case letter
    case legal
    case tabloid
    case a4
    case a3

    /// The default — matches the page size the exporter used before this picker
    /// existed, so an export left untouched is byte-for-byte the old behavior.
    static let `default`: PaperSize = .elevenByFourteen

    /// Portrait page size in points (1 pt = 1/72 in).
    var size: CGSize {
        switch self {
        case .elevenByFourteen: return CGSize(width: 792, height: 1008)  // 11 × 14 in
        case .letter:           return CGSize(width: 612, height: 792)   // 8.5 × 11 in
        case .legal:            return CGSize(width: 612, height: 1008)  // 8.5 × 14 in
        case .tabloid:          return CGSize(width: 792, height: 1224)  // 11 × 17 in
        case .a4:               return CGSize(width: 595, height: 842)   // 210 × 297 mm
        case .a3:               return CGSize(width: 842, height: 1191)  // 297 × 420 mm
        }
    }

    /// Localized label for the save-panel popup. AppKit popup titles are not
    /// auto-extracted, so each is wrapped explicitly. "11 × 14 in" keeps its
    /// unit to read as a size rather than a ratio; the rest are standard names.
    var displayName: String {
        switch self {
        case .elevenByFourteen: return String(localized: "11 × 14 in")
        case .letter:           return String(localized: "Letter")
        case .legal:            return String(localized: "Legal")
        case .tabloid:          return String(localized: "Tabloid")
        case .a4:               return String(localized: "A4")
        case .a3:               return String(localized: "A3")
        }
    }
}
