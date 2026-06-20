//
//  FileMetadata.swift
//  Muse
//
//  Extra per-file metadata shown in the hero viewer's INFO card: photo EXIF
//  (date taken / camera / lens / exposure / location), PDF document properties,
//  and A/V duration. Read on viewer-open only — never persisted (no DB column).
//
//  The formatting is pure (testable from raw header dictionaries); `load`
//  is the thin IO wrapper that reads the headers per AssetKind.
//

import Foundation

struct InfoRow: Identifiable, Equatable {
    let id: UUID
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.id = UUID()
        self.label = label
        self.value = value
    }
    // UUID is per-instance; compare on content so tests are deterministic.
    static func == (a: InfoRow, b: InfoRow) -> Bool {
        a.label == b.label && a.value == b.value
    }
}

struct Coordinate: Equatable {
    let lat: Double
    let long: Double
}

struct FileMetadata: Equatable {
    var rows: [InfoRow]
    var coordinate: Coordinate?

    static let empty = FileMetadata(rows: [], coordinate: nil)

    // MARK: - Pure image formatting

    /// Build INFO rows + coordinate from the three CGImageSource sub-dictionaries.
    /// Keys are the bare suffixes (e.g. "FNumber"), matching the kCGImageProperty
    /// constant names with their prefixes stripped.
    static func imageMetadata(exif: [String: Any], tiff: [String: Any],
                              gps: [String: Any]) -> FileMetadata {
        var rows: [InfoRow] = []

        if let taken = formatTakenDate(exif["DateTimeOriginal"] as? String) {
            rows.append(InfoRow("Taken", taken))
        }
        if let camera = camera(make: tiff["Make"] as? String, model: tiff["Model"] as? String) {
            rows.append(InfoRow("Camera", camera))
        }
        if let lens = (exif["LensModel"] as? String)?.trimmingCharacters(in: .whitespaces),
           !lens.isEmpty {
            rows.append(InfoRow("Lens", lens))
        }
        let iso = (exif["ISOSpeedRatings"] as? [Int])?.first ?? (exif["ISOSpeedRatings"] as? Int)
        if let exposure = formatExposure(fNumber: exif["FNumber"] as? Double,
                                         exposureTime: exif["ExposureTime"] as? Double,
                                         iso: iso) {
            rows.append(InfoRow("Exposure", exposure))
        }
        let coord = coordinate(latitude: gps["Latitude"] as? Double,
                               latRef: gps["LatitudeRef"] as? String,
                               longitude: gps["Longitude"] as? Double,
                               longRef: gps["LongitudeRef"] as? String)
        if let coord {
            rows.append(InfoRow("Location", String(format: "%.4f, %.4f", coord.lat, coord.long)))
        }
        return FileMetadata(rows: rows, coordinate: coord)
    }

    private static func camera(make: String?, model: String?) -> String? {
        let m = make?.trimmingCharacters(in: .whitespaces)
        let mod = model?.trimmingCharacters(in: .whitespaces)
        switch (m, mod) {
        case let (m?, mod?) where !m.isEmpty && !mod.isEmpty:
            // Avoid "Apple Apple ..." when the model already starts with the make.
            return mod.hasPrefix(m) ? mod : "\(m) \(mod)"
        case let (m?, _) where !m.isEmpty: return m
        case let (_, mod?) where !mod.isEmpty: return mod
        default: return nil
        }
    }

    static func formatTakenDate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: raw) else { return nil }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }

    static func formatExposure(fNumber: Double?, exposureTime: Double?, iso: Int?) -> String? {
        var parts: [String] = []
        if let f = fNumber {
            // Trim trailing ".0" (ƒ2 not ƒ2.0); keep one decimal otherwise.
            let s = f == f.rounded() ? String(format: "ƒ%.0f", f) : String(format: "ƒ%.1f", f)
            parts.append(s)
        }
        if let t = exposureTime, t > 0 {
            if t >= 1 {
                parts.append(String(format: "%gs", t))
            } else {
                parts.append("1/\(Int((1.0 / t).rounded()))")
            }
        }
        if let iso { parts.append("ISO \(iso)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func coordinate(latitude: Double?, latRef: String?,
                           longitude: Double?, longRef: String?) -> Coordinate? {
        guard let lat = latitude, let long = longitude else { return nil }
        let signedLat = (latRef?.uppercased() == "S") ? -abs(lat) : lat
        let signedLong = (longRef?.uppercased() == "W") ? -abs(long) : long
        return Coordinate(lat: signedLat, long: signedLong)
    }

    // MARK: - Pure PDF formatting

    /// `attributes` keys are the bare PDFDocumentAttribute suffixes
    /// ("Title", "Author", "Creator") — the loader maps PDFKit's keys to these.
    static func pdfMetadata(pageCount: Int, attributes: [String: Any]) -> FileMetadata {
        var rows: [InfoRow] = [InfoRow("Pages", "\(pageCount)")]
        for key in ["Title", "Author", "Creator"] {
            if let v = (attributes[key] as? String)?.trimmingCharacters(in: .whitespaces),
               !v.isEmpty {
                rows.append(InfoRow(key, v))
            }
        }
        return FileMetadata(rows: rows, coordinate: nil)
    }

    // MARK: - Pure media formatting

    static func formatDuration(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    static func mediaMetadata(durationSeconds: Double?) -> FileMetadata {
        guard let d = formatDuration(durationSeconds) else { return .empty }
        return FileMetadata(rows: [InfoRow("Duration", d)], coordinate: nil)
    }
}
