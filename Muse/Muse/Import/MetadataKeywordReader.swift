//
//  MetadataKeywordReader.swift
//  Muse
//
//  Read-only extraction of the keywords + star rating other tools
//  (Lightroom, Bridge, Capture One) wrote into an image. Priority PER FIELD:
//  .xmp sidecar → embedded XMP (dc:subject / xmp:Rating via CGImageMetadata)
//  → embedded IPTC (legacy fallback). Metadata-only reads — never decodes
//  pixels, so the 300 MP decode budget isn't in play — and never touches a
//  dataless iCloud placeholder (reading would force a download; same guard
//  as AssetKind / FileMetadata).
//

import Foundation
import ImageIO

enum MetadataKeywordReader {

    /// A coordinate as a value type — a `(lat, lon)` tuple would break
    /// `Equatable` synthesis, and this mirrors `ImportSupplement.External`.
    struct Coordinate: Equatable, Sendable {
        var lat: Double
        var lon: Double
    }

    struct Extracted: Equatable, Sendable {
        var keywords: [String] = []
        var rating: Int? = nil
        /// `xmp:Label` — the raw source string, verbatim. Never mapped here;
        /// the user decides what a label means (DECIDED #12).
        var label: String? = nil
        /// `dc:title` [Alt, first] → IPTC ObjectName.
        var title: String? = nil
        /// `dc:description` [Alt, first] → IPTC CaptionAbstract.
        var caption: String? = nil
        /// `dc:creator` [Seq, first] → IPTC Byline.
        var creator: String? = nil
        /// XMP-format GPS — the one coordinate source the image header can't
        /// reach (a sidecar-only RAW workflow).
        var coordinate: Coordinate? = nil

        var isEmpty: Bool {
            keywords.isEmpty && rating == nil && label == nil && title == nil
                && caption == nil && creator == nil && coordinate == nil
        }
        var complete: Bool {
            !keywords.isEmpty && rating != nil && label != nil && title != nil
                && caption != nil && creator != nil && coordinate != nil
        }
    }

    enum ReadError: Error {
        /// Not-downloaded iCloud placeholder — skipped, never force-downloaded.
        case dataless
        /// Neither the file nor a sidecar could be opened as metadata.
        case unreadable
    }

    /// Files with no keywords/rating return an empty `Extracted` (the caller
    /// counts "had none"); dataless placeholders and unopenable files throw
    /// (counted "skipped"). Call off-main.
    static func read(url: URL) throws -> Extracted {
        try readFull(url: url, includingLightroom: false).extracted
    }

    /// The same single metadata resolve, optionally also parsing Adobe's `crs:`
    /// development settings out of it. One pass, zero extra I/O — the Lightroom
    /// edit import rides the metadata the keyword reader already opened.
    static func readFull(url: URL, includingLightroom: Bool)
        throws -> (extracted: Extracted, lightroom: LightroomEdits?) {
        if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus == .notDownloaded {
            throw ReadError.dataless
        }
        let sidecar = sidecarMetadata(for: url)
        // CGImageSourceCreateWithURL succeeds lazily even on garbage bytes, so
        // presence alone isn't "readable image". Image COUNT is the robust
        // signal: garbage → 0, any real container (incl. every ImageIO-supported
        // RAW) → ≥1. (Status is NOT used — it isn't reliably .statusComplete for
        // all RAW formats, which are exactly the files that carry sidecars, so a
        // status gate would wrongly skip a readable RAW.) A file with neither a
        // sidecar nor a decodable container throws (counted "skipped").
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let hasImages = (source.map { CGImageSourceGetCount($0) } ?? 0) > 0
        guard sidecar != nil || hasImages else { throw ReadError.unreadable }

        var out = Extracted()
        var lightroom: LightroomEdits?
        if let sidecar {
            merge(from: sidecar, into: &out)
            if includingLightroom { lightroom = LightroomXMP.read(sidecar) }
        }
        if hasImages, let source, !out.complete || (includingLightroom && lightroom == nil) {
            if let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                merge(from: meta, into: &out)
                // Sidecar wins: Lightroom writes the CURRENT develop settings
                // there, and an embedded block can be an older export.
                if includingLightroom, lightroom == nil { lightroom = LightroomXMP.read(meta) }
            }
            if !out.complete { mergeIPTC(from: source, into: &out) }
        }
        return (out, lightroom.flatMap { $0.isEmpty && $0.unsupported.isEmpty ? nil : $0 })
    }

    // MARK: - Sidecar

    /// Lightroom/Capture One write `IMG_1234.xmp` beside `IMG_1234.cr2`
    /// (replaced extension); some tools append instead (`IMG_1234.cr2.xmp`).
    /// Checked for every kind, not just RAW — harmless when absent.
    private static func sidecarMetadata(for url: URL) -> CGImageMetadata? {
        let candidates = [
            url.deletingPathExtension().appendingPathExtension("xmp"),
            url.appendingPathExtension("xmp"),
        ]
        for candidate in candidates {
            // Size-capped before the read — see `BoundedRead`.
            guard let data = BoundedRead.metadata(at: candidate),
                  let meta = CGImageMetadataCreateFromXMPData(data as CFData)
            else { continue }
            return meta
        }
        return nil
    }

    // MARK: - XMP (sidecar or embedded)

    /// Fill only the fields still missing — this is what gives the per-field
    /// sidecar → embedded priority.
    private static func merge(from meta: CGImageMetadata, into out: inout Extracted) {
        if out.keywords.isEmpty {
            out.keywords = MetadataImportRules.normalizeKeywords(xmpSubjects(meta))
        }
        if out.rating == nil,
           let tag = CGImageMetadataCopyTagWithPath(meta, nil, "xmp:Rating" as CFString) {
            out.rating = MetadataImportRules.normalizeRating(doubleValue(of: tag))
        }
        // `xmp:Label` is a plain string tag — no IPTC equivalent exists, so it
        // is XMP/sidecar-only by nature.
        if out.label == nil { out.label = xmpString(meta, "xmp:Label") }
        if out.title == nil { out.title = xmpString(meta, "dc:title") }
        if out.caption == nil { out.caption = xmpString(meta, "dc:description") }
        if out.creator == nil { out.creator = xmpString(meta, "dc:creator") }
        if out.coordinate == nil,
           let pair = XMPGPS.coordinate(lat: xmpString(meta, "exif:GPSLatitude"),
                                        lon: xmpString(meta, "exif:GPSLongitude")) {
            out.coordinate = Coordinate(lat: pair.0, lon: pair.1)
        }
    }

    /// One reader for the three XMP container shapes: a bare string, or an
    /// Alt/Seq/Bag array whose elements are child tags (occasionally raw
    /// strings — the same tolerance `xmpSubjects` already needs).
    private static func xmpString(_ meta: CGImageMetadata, _ path: String) -> String? {
        guard let tag = CGImageMetadataCopyTagWithPath(meta, nil, path as CFString),
              let value = CGImageMetadataTagCopyValue(tag) else { return nil }
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
            else { return nil }
            return t
        }
        if let single = value as? String { return clean(single) }
        guard let items = value as? [Any] else { return nil }
        for item in items {
            let ref = item as CFTypeRef
            if CFGetTypeID(ref) == CGImageMetadataTagGetTypeID() {
                let itemTag = unsafeDowncast(ref as AnyObject, to: CGImageMetadataTag.self)
                if let s = clean(CGImageMetadataTagCopyValue(itemTag) as? String) { return s }
            } else if let s = clean(item as? String) {
                return s
            }
        }
        return nil
    }

    /// `dc:subject` is an XMP Bag: its tag value is an array whose elements
    /// are child CGImageMetadataTags (occasionally raw strings — handle both).
    private static func xmpSubjects(_ meta: CGImageMetadata) -> [String] {
        guard let tag = CGImageMetadataCopyTagWithPath(meta, nil, "dc:subject" as CFString),
              let value = CGImageMetadataTagCopyValue(tag) else { return [] }
        if let single = value as? String { return [single] }
        guard let items = value as? [Any] else { return [] }
        return items.compactMap { item in
            let ref = item as CFTypeRef
            if CFGetTypeID(ref) == CGImageMetadataTagGetTypeID() {
                let itemTag = unsafeDowncast(ref as AnyObject, to: CGImageMetadataTag.self)
                return CGImageMetadataTagCopyValue(itemTag) as? String
            }
            return item as? String
        }
    }

    private static func doubleValue(of tag: CGImageMetadataTag) -> Double? {
        guard let value = CGImageMetadataTagCopyValue(tag) else { return nil }
        if let str = value as? String { return Double(str) }
        return (value as? NSNumber)?.doubleValue
    }

    // MARK: - IPTC (legacy fallback)

    /// Header-only properties read (no pixel decode) — the pre-XMP path older
    /// tools wrote: IPTC Keywords + IPTC star rating.
    private static func mergeIPTC(from source: CGImageSource, into out: inout Extracted) {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        else { return }
        if out.keywords.isEmpty {
            let raw = (iptc[kCGImagePropertyIPTCKeywords] as? [String])
                ?? (iptc[kCGImagePropertyIPTCKeywords] as? String).map { [$0] }
                ?? []
            out.keywords = MetadataImportRules.normalizeKeywords(raw)
        }
        if out.rating == nil, let n = iptc[kCGImagePropertyIPTCStarRating] as? NSNumber {
            out.rating = MetadataImportRules.normalizeRating(n.doubleValue)
        }
        // Array-or-string tolerant, like Keywords — take the first entry.
        func first(_ key: CFString) -> String? {
            let raw = (iptc[key] as? [String])?.first ?? (iptc[key] as? String)
            guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
            else { return nil }
            return t
        }
        if out.title == nil { out.title = first(kCGImagePropertyIPTCObjectName) }
        if out.caption == nil { out.caption = first(kCGImagePropertyIPTCCaptionAbstract) }
        if out.creator == nil { out.creator = first(kCGImagePropertyIPTCByline) }
    }
}
