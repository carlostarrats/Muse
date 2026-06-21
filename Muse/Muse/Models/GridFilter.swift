//
//  GridFilter.swift
//  Muse
//
//  Pure, unit-testable faceted filter for the grid: narrow the visible tiles by
//  kind (image/video/pdf/document/audio/other), modified-date preset, and size
//  bucket. Mirrors the shape of ImageLayout / TileBackground — a value type +
//  matcher persisted via AppSettings and mirrored on AppState. `matches` takes
//  raw inputs (kind/size/modified) and an injected `now` so date windows are
//  deterministic in tests; the source of those values (FileNode) is an
//  implementation detail of the caller. NOT a sort — it removes non-matching
//  files from whichever set is active (folder / collection / tag / search).
//

import Foundation

/// Grouped kind buckets the filter exposes. Several `AssetKind`s collapse into
/// each bucket (e.g. raw/psd/svg → image); anything unhandled → `.other`.
/// `folder` is its own facet so the one-level browse view's subfolder cards can
/// be toggled on/off independently (feat/next-42 follow-up).
enum KindFacet: String, CaseIterable, Identifiable, Codable {
    case image, video, pdf, document, audio, folder, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .image:    return "Images"
        case .video:    return "Videos"
        case .pdf:      return "PDFs"
        case .document: return "Documents"
        case .audio:    return "Audio"
        case .folder:   return "Folders"
        case .other:    return "Other"
        }
    }

    init(from kind: AssetKind) {
        switch kind {
        case .image, .raw, .psd, .svg:         self = .image
        case .video:                           self = .video
        case .pdf:                             self = .pdf
        case .text, .markdown, .code, .office: self = .document
        case .audio:                           self = .audio
        case .folder:                          self = .folder
        case .model3d, .font, .archive, .unknown:
            self = .other
        }
    }
}

/// Modified-date preset. `.any` = no date constraint.
enum DateFacet: String, CaseIterable, Identifiable, Codable {
    case any, today, week, month, year

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .any:   return "Any"
        case .today: return "Today"
        case .week:  return "This Week"
        case .month: return "This Month"
        case .year:  return "This Year"
        }
    }

    /// Inclusive lower bound of the window relative to `now`, or nil for `.any`.
    func windowStart(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .any:   return nil
        case .today: return calendar.startOfDay(for: now)
        case .week:  return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .month: return calendar.dateInterval(of: .month, for: now)?.start
        case .year:  return calendar.dateInterval(of: .year, for: now)?.start
        }
    }
}

/// Size bucket using decimal MB (1 MB = 1,000,000 bytes, matching Finder).
/// `.any` = no size constraint.
enum SizeFacet: String, CaseIterable, Identifiable, Codable {
    case any, under1MB, mb1to10, mb10to100, over100MB

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .any:       return "Any"
        case .under1MB:  return "< 1 MB"
        case .mb1to10:   return "1–10 MB"
        case .mb10to100: return "10–100 MB"
        case .over100MB: return "> 100 MB"
        }
    }

    private static let MB: Int64 = 1_000_000

    func contains(_ bytes: Int64) -> Bool {
        switch self {
        case .any:       return true
        case .under1MB:  return bytes < 1 * Self.MB
        case .mb1to10:   return bytes >= 1 * Self.MB && bytes < 10 * Self.MB
        case .mb10to100: return bytes >= 10 * Self.MB && bytes < 100 * Self.MB
        case .over100MB: return bytes >= 100 * Self.MB
        }
    }
}

struct GridFilter: Equatable, Codable {
    /// Empty = no kind constraint (all kinds shown).
    var kinds: Set<KindFacet>
    var date: DateFacet
    var size: SizeFacet

    static let none = GridFilter(kinds: [], date: .any, size: .any)

    /// True when any facet constrains the result.
    var isActive: Bool {
        !kinds.isEmpty || date != .any || size != .any
    }

    /// Pure predicate. `now` injected so date windows are deterministic in tests.
    func matches(kind: AssetKind, sizeBytes: Int64?, modified: Date?, now: Date) -> Bool {
        let facet = KindFacet(from: kind)
        if !kinds.isEmpty {
            guard kinds.contains(facet) else { return false }
        }
        // Folders are matched ONLY by the kind facet — date/size are file
        // concepts that never apply to a directory, so a date/size filter must
        // not hide a folder the kind facet kept (folders are navigation).
        if facet == .folder { return true }
        if let start = date.windowStart(now: now) {
            guard let modified, modified >= start else { return false }
        }
        if size != .any {
            guard let sizeBytes, size.contains(sizeBytes) else { return false }
        }
        return true
    }

    /// Decode a persisted JSON string, defaulting to `.none` when missing/invalid.
    static func resolve(_ raw: String?) -> GridFilter {
        guard let raw, let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(GridFilter.self, from: data)
        else { return .none }
        return decoded
    }
}
