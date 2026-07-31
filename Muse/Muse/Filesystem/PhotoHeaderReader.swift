//
//  PhotoHeaderReader.swift
//  Muse
//
//  One header-only read serving BOTH coordinates and EXIF — a single
//  CGImageSourceCopyPropertiesAtIndex call rather than two separate readers
//  parsing the same header twice. Supersedes Spec 01's CoordinateReader.
//
//  Key handling mirrors FileMetadata.imageMetadata exactly: the same
//  prefix-stripped bare keys ("FNumber", "Make", "Latitude"), the same
//  ISOSpeedRatings array-or-scalar tolerance, and the same pure
//  `FileMetadata.coordinate` / `FileMetadata.parseISO6709` calls. The two
//  must never diverge, or the viewer shows one camera/location while search
//  indexes another.
//
//  Header-only: no decode, no full-file read. A dataless iCloud placeholder is
//  skipped rather than forced to download, same guard as `FileMetadata.load`
//  and `Indexer.isDataless`.
//

import Foundation
import ImageIO
import AVFoundation

nonisolated struct ExifFields: Equatable, Sendable {
    var captureDate: Int64?
    var captureMD: String?
    var cameraMake: String?
    var cameraModel: String?
    var lens: String?
    var iso: Int?
    var fNumber: Double?
    var exposureSeconds: Double?
    var focalLength: Double?
    var focalLength35mm: Int?
    var flashFired: Bool?
}

nonisolated struct PhotoHeader: Sendable {
    var coordinate: Coordinate?
    var exif: ExifFields?
}

nonisolated enum PhotoHeaderReader {

    static func read(url: URL, kind: AssetKind) async -> PhotoHeader {
        // Dataless iCloud placeholders never force a download.
        guard !isDataless(url) else { return PhotoHeader() }
        switch kind {
        case .image, .raw, .psd:
            return readImageHeader(url: url)
        case .video:
            return await readVideoHeader(url: url)
        default:
            return PhotoHeader()
        }
    }

    /// Rejects non-finite and out-of-range values — a corrupt header must not
    /// put a pin in the sea.
    static func sanitize(_ c: Coordinate) -> Coordinate? {
        guard c.lat.isFinite, c.long.isFinite,
              abs(c.lat) <= 90, abs(c.long) <= 180 else { return nil }
        return c
    }

    /// Pure mapping over prefix-stripped bare keys, exactly the shape
    /// `FileMetadata.imageMetadata` consumes.
    static func exifFields(exif: [String: Any], tiff: [String: Any]) -> ExifFields {
        func intValue(_ v: Any?) -> Int? {
            // Some encoders write ISOSpeedRatings as a single-element array
            // rather than a scalar — FileMetadata already tolerates both.
            if let arr = v as? [Int] { return arr.first }
            if let n = v as? NSNumber { return n.intValue }
            if let i = v as? Int { return i }
            return nil
        }
        func doubleValue(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let d = v as? Double { return d }
            return nil
        }
        func trimmed(_ v: Any?) -> String? {
            guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty else { return nil }
            return s
        }

        var fields = ExifFields()
        fields.iso = intValue(exif["ISOSpeedRatings"])
        fields.fNumber = doubleValue(exif["FNumber"])
        fields.exposureSeconds = doubleValue(exif["ExposureTime"])
        fields.focalLength = doubleValue(exif["FocalLength"])
        fields.focalLength35mm = intValue(exif["FocalLenIn35mmFilm"])
        fields.lens = trimmed(exif["LensModel"])
        fields.cameraMake = trimmed(tiff["Make"])
        fields.cameraModel = trimmed(tiff["Model"])
        // EXIF Flash is a bitfield; bit 0 = fired.
        if let flash = intValue(exif["Flash"]) {
            fields.flashFired = (flash & 1) == 1
        }
        if let parsed = parseExifDate(exif["DateTimeOriginal"] as? String) {
            fields.captureDate = parsed.epoch
            fields.captureMD = parsed.md
        }
        return fields
    }

    /// "yyyy:MM:dd HH:mm:ss", en_US_POSIX, interpreted in the CURRENT LOCAL
    /// time zone — EXIF carries no zone; local time is the Photos-app
    /// convention and the least-wrong default (recorded limitation, not a
    /// bug), and it matches `FileMetadata.formatTakenDate`'s own parse.
    /// `md` derives from the SAME Date so the two can never disagree.
    static func parseExifDate(_ s: String?) -> (epoch: Int64, md: String)? {
        guard let s, !s.isEmpty else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: s) else { return nil }
        return (Int64(date.timeIntervalSince1970), monthDay(date))
    }

    /// The materialized "MM-DD" On This Day key.
    static func monthDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd"
        return f.string(from: date)
    }

    // MARK: - Private

    private static func isDataless(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus == .notDownloaded
    }

    private static func readImageHeader(url: URL) -> PhotoHeader {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return PhotoHeader() }

        // Strip the kCGImageProperty*<Group>* prefixes so the pure functions
        // see bare keys — the same helper shape FileMetadata.loadImage uses.
        func sub(_ key: CFString) -> [String: Any] {
            guard let dict = props[key] as? [CFString: Any] else { return [:] }
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k as String] = v }
            return out
        }

        let gps = sub(kCGImagePropertyGPSDictionary)
        let coordinate = FileMetadata.coordinate(
            latitude: gps["Latitude"] as? Double,
            latRef: gps["LatitudeRef"] as? String,
            longitude: gps["Longitude"] as? Double,
            longRef: gps["LongitudeRef"] as? String).flatMap(sanitize)

        let exifDict = sub(kCGImagePropertyExifDictionary)
        let tiffDict = sub(kCGImagePropertyTIFFDictionary)
        let exif = (exifDict.isEmpty && tiffDict.isEmpty)
            ? nil : exifFields(exif: exifDict, tiff: tiffDict)

        return PhotoHeader(coordinate: coordinate, exif: exif)
    }

    private static func readVideoHeader(url: URL) async -> PhotoHeader {
        // Reference-restricted asset — a QuickTime reference movie must never
        // resolve a remote data ref just because we asked for its metadata.
        let asset = AVURLAsset.noNetwork(url: url)
        guard let metadata = try? await asset.load(.metadata) else { return PhotoHeader() }

        var coordinate: Coordinate?
        var recorded: Date?
        for item in metadata {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyLocation where coordinate == nil:
                if let s = try? await item.load(.stringValue) {
                    coordinate = FileMetadata.parseISO6709(s).flatMap(sanitize)
                }
            case .commonKeyCreationDate where recorded == nil:
                if let d = try? await item.load(.dateValue) { recorded = d }
            default:
                break
            }
        }

        // Video carries no EXIF beyond the capture date; every other field
        // stays nil.
        var exif: ExifFields?
        if let recorded {
            var f = ExifFields()
            f.captureDate = Int64(recorded.timeIntervalSince1970)
            f.captureMD = monthDay(recorded)
            exif = f
        }
        return PhotoHeader(coordinate: coordinate, exif: exif)
    }
}
