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
import ImageIO
import PDFKit
import AVFoundation
import UniformTypeIdentifiers

nonisolated struct InfoRow: Identifiable, Equatable {
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

nonisolated struct Coordinate: Equatable {
    let lat: Double
    let long: Double
}

nonisolated struct FileMetadata: Equatable {
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

    /// Frame rate as a tidy integer when close to one (29.97 → "30 fps"),
    /// else two decimals. nil for missing/zero.
    static func formatFrameRate(_ fps: Float?) -> String? {
        guard let fps, fps > 0 else { return nil }
        let rounded = fps.rounded()
        if abs(fps - rounded) < 0.1 { return "\(Int(rounded)) fps" }
        return String(format: "%.2f fps", fps)
    }

    /// A video's capture date (medium date + short time), paralleling photos'
    /// "Taken". nil when no date.
    static func formatRecordedDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }

    /// Parse an ISO 6709 location string (e.g. "+34.0522-118.2437+096.000/",
    /// as embedded in iPhone video metadata) → signed lat/long. nil if it
    /// doesn't start with a signed lat+long pair.
    static func parseISO6709(_ s: String?) -> Coordinate? {
        guard let s else { return nil }
        let pattern = #"([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let latR = Range(m.range(at: 1), in: s),
              let longR = Range(m.range(at: 2), in: s),
              let lat = Double(s[latR]), let long = Double(s[longR]) else { return nil }
        return Coordinate(lat: lat, long: long)
    }

    /// Assemble a video's INFO rows: Recorded · Dimensions · Duration ·
    /// Frame Rate (the "Modified" row is added by `load`). The coordinate is
    /// surfaced (drives the "Open in Maps" link) but NOT shown as a text row —
    /// the link is the location affordance, so the raw lat/long is redundant.
    static func videoMetadata(durationSeconds: Double?,
                              dimensions: (width: Int, height: Int)?,
                              frameRate: Float?, recorded: Date?,
                              coordinate: Coordinate?) -> FileMetadata {
        var rows: [InfoRow] = []
        if let s = formatRecordedDate(recorded) { rows.append(InfoRow("Recorded", s)) }
        if let dim = dimensions, dim.width > 0, dim.height > 0 {
            rows.append(InfoRow("Dimensions", "\(dim.width) × \(dim.height)"))
        }
        if let d = formatDuration(durationSeconds) { rows.append(InfoRow("Duration", d)) }
        if let fps = formatFrameRate(frameRate) { rows.append(InfoRow("Frame Rate", fps)) }
        return FileMetadata(rows: rows, coordinate: coordinate)
    }

    // MARK: - Pure file-attribute formatting

    /// Filesystem modification date as a medium date with NO time, to match the
    /// other INFO date rows' density (e.g. "Jun 17, 2026"). nil when no date.
    static func formatModifiedDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df.string(from: date)
    }

    /// On-disk size. Bytes are in the allowed units on purpose: capped at KB and
    /// up, a small SVG or text file reads "0 KB", which is worse than the raw
    /// count it was meant to spare the reader. Anything past 1 KB formats the
    /// same either way. nil for a missing or zero size.
    static func formatFileSize(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }

    /// The system's human name for the file's type ("JPEG image"), falling back
    /// to the bare uppercased extension when the type isn't registered. nil for
    /// an extensionless file. Display-only — nothing derived from this is stored.
    static func formatFileKind(extension ext: String) -> String? {
        let e = ext.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty else { return nil }
        if let type = UTType(filenameExtension: e),
           let desc = type.localizedDescription?.trimmingCharacters(in: .whitespaces),
           !desc.isEmpty {
            return desc
        }
        return e.uppercased()
    }

    /// Pixel count in megapixels, one decimal below 10 where the tenths still
    /// mean something. The BARE number — the row's label is the unit ("MP"), so
    /// spelling it out here would print it twice. Computed in Double: a hostile
    /// header can declare dimensions whose product overflows Int. nil below
    /// 0.1 MP (icons/sprites — "0.0" says nothing).
    static func formatMegapixels(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        let mp = (Double(width) * Double(height)) / 1_000_000
        guard mp >= 0.1 else { return nil }
        return mp < 10 ? String(format: "%.1f", mp) : String(format: "%.0f", mp)
    }

    /// Splice the rows that apply to EVERY file — Modified · Size · Format, plus
    /// Dimensions · MP for a still image — into `rows` from the per-kind
    /// loader. These are filesystem attributes and header reads, not byte reads,
    /// which is why the INFO card shows for any non-dataless file rather than
    /// only those carrying photo/PDF/AV metadata.
    ///
    /// They sit directly under the capture-date row when there is one ("Taken"
    /// for photos, "Recorded" for videos), else at the top. The insertion point
    /// is anchored on the CAPTURE date, not on the Modified row: a file with a
    /// capture date but no modification date would otherwise push its facts
    /// above the date it was taken.
    ///
    /// `dimensions` is nil for anything that isn't a still image — a video
    /// already carries its own Dimensions row (from the track's transformed
    /// natural size) and must not get a second one.
    static func withFileFacts(_ rows: [InfoRow], modified: Date?, sizeBytes: Int64?,
                              fileExtension: String,
                              dimensions: (width: Int, height: Int)?) -> [InfoRow] {
        var out = rows
        var at = out.firstIndex(where: { $0.label == "Taken" || $0.label == "Recorded" })
            .map { $0 + 1 } ?? 0
        if let s = formatModifiedDate(modified) {
            out.insert(InfoRow("Modified", s), at: at)
            at += 1
        }
        var facts: [InfoRow] = []
        if let s = formatFileSize(sizeBytes) { facts.append(InfoRow("Size", s)) }
        if let k = formatFileKind(extension: fileExtension) { facts.append(InfoRow("Format", k)) }
        if let d = dimensions, d.width > 0, d.height > 0 {
            facts.append(InfoRow("Dimensions", "\(d.width) × \(d.height)"))
            if let mp = formatMegapixels(width: d.width, height: d.height) {
                facts.append(InfoRow("MP", mp))
            }
        }
        out.insert(contentsOf: facts, at: at)
        return out
    }

    // MARK: - IO loader (not unit-tested: CG/PDFKit/AVFoundation layer)

    /// Read header metadata off-main for `url`, dispatched by `kind`. Returns
    /// `.empty` for kinds without extra metadata, for dataless iCloud
    /// placeholders (never forces a download), and on any read failure.
    static func load(url: URL, kind: AssetKind) async -> FileMetadata {
        // Never read bytes of a not-yet-downloaded iCloud file (mirrors
        // AssetKind.isDataless / the Indexer dataless rule).
        if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus == .notDownloaded {
            return .empty
        }
        return await Task.detached(priority: .userInitiated) { () -> FileMetadata in
            var result: FileMetadata
            switch kind {
            case .image, .raw, .psd:
                result = loadImage(url: url)
            case .pdf:
                result = loadPDF(url: url)
            case .video:
                result = await loadVideo(url: url)
            case .audio:
                result = await loadMedia(url: url)
            default:
                result = .empty
            }
            // A file that can't be stat'd is gone or unreadable — a viewer can
            // outlive the file it's showing (an external delete, the burn-delete
            // undo window). Bail rather than fall through, or Format would still
            // be inferred from the path's extension and the card would assert a
            // type for a file that isn't there.
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                                 .fileSizeKey])
            else { return result }
            // Still-image dimensions come from the header via
            // ImageHeaderSizeCache — the single orientation-applied dimension
            // truth the grid and the hero flight also read, so a rotated photo
            // reports what it SHOWS. It's warmed off-main by the thumbnail pass,
            // so this is normally a dictionary lookup, and it's available
            // whether or not the file has been analyzed (the DB's width/height
            // are analysis-only).
            var dimensions: (width: Int, height: Int)? = nil
            switch kind {
            case .image, .raw, .psd:
                if let px = ImageHeaderSizeCache.resolve(url) {
                    dimensions = (Int(px.width), Int(px.height))
                }
            default:
                break
            }
            result.rows = withFileFacts(result.rows,
                                        modified: values.contentModificationDate,
                                        sizeBytes: values.fileSize.map(Int64.init),
                                        fileExtension: url.pathExtension,
                                        dimensions: dimensions)
            return result
        }.value
    }

    private static func loadImage(url: URL) -> FileMetadata {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return .empty }
        // Strip the kCGImageProperty*<Group>* prefixes so the pure functions see
        // bare keys ("FNumber", "Make", "Latitude").
        func sub(_ key: CFString) -> [String: Any] {
            guard let dict = props[key] as? [CFString: Any] else { return [:] }
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k as String] = v }
            return out
        }
        return imageMetadata(exif: sub(kCGImagePropertyExifDictionary),
                             tiff: sub(kCGImagePropertyTIFFDictionary),
                             gps: sub(kCGImagePropertyGPSDictionary))
    }

    private static func loadPDF(url: URL) -> FileMetadata {
        guard let doc = PDFDocument(url: url) else { return .empty }
        let raw = doc.documentAttributes ?? [:]
        var attrs: [String: Any] = [:]
        // PDFKit keys are PDFDocumentAttribute (e.g. .titleAttribute) → bare names.
        if let t = raw[PDFDocumentAttribute.titleAttribute] { attrs["Title"] = t }
        if let a = raw[PDFDocumentAttribute.authorAttribute] { attrs["Author"] = a }
        if let c = raw[PDFDocumentAttribute.creatorAttribute] { attrs["Creator"] = c }
        return pdfMetadata(pageCount: doc.pageCount, attributes: attrs)
    }

    private static func loadMedia(url: URL) async -> FileMetadata {
        let asset = AVURLAsset.noNetwork(url: url)
        guard let duration = try? await asset.load(.duration) else { return .empty }
        let seconds = CMTimeGetSeconds(duration)
        return mediaMetadata(durationSeconds: seconds.isFinite ? seconds : nil)
    }

    private static func loadVideo(url: URL) async -> FileMetadata {
        let asset = AVURLAsset.noNetwork(url: url)
        let seconds: Double? = (try? await asset.load(.duration))
            .map { CMTimeGetSeconds($0) }
            .flatMap { ($0.isFinite && $0 > 0) ? $0 : nil }

        var dimensions: (width: Int, height: Int)? = nil
        var frameRate: Float? = nil
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let applied = size.applying(transform)
                let w = Int(abs(applied.width).rounded()), h = Int(abs(applied.height).rounded())
                if w > 0, h > 0 { dimensions = (w, h) }
            }
            if let fps = try? await track.load(.nominalFrameRate) { frameRate = fps }
        }

        // Capture date + GPS from the asset's common metadata (iPhone videos
        // carry both). dateValue is the primary path; fall back to parsing a
        // string. Location is an ISO 6709 string → coordinate (drives the same
        // "Open in Maps" link as photos).
        var recorded: Date? = nil
        var coordinate: Coordinate? = nil
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyCreationDate where recorded == nil:
                    if let d = try? await item.load(.dateValue) {
                        recorded = d
                    } else if let s = try? await item.load(.stringValue) {
                        recorded = parseMetadataDate(s)
                    }
                case .commonKeyLocation where coordinate == nil:
                    if let s = try? await item.load(.stringValue) {
                        coordinate = parseISO6709(s)
                    }
                default:
                    break
                }
            }
        }

        return videoMetadata(durationSeconds: seconds, dimensions: dimensions,
                             frameRate: frameRate, recorded: recorded, coordinate: coordinate)
    }

    /// ISO 8601 fallback for a creation-date string when `.dateValue` is absent.
    private static func parseMetadataDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s)
    }
}
