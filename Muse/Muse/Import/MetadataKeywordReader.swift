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

    struct Extracted: Equatable {
        var keywords: [String] = []
        var rating: Int? = nil
        var isEmpty: Bool { keywords.isEmpty && rating == nil }
        fileprivate var complete: Bool { !keywords.isEmpty && rating != nil }
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
        if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus == .notDownloaded {
            throw ReadError.dataless
        }
        let sidecar = sidecarMetadata(for: url)
        // CGImageSourceCreateWithURL succeeds lazily even on garbage bytes —
        // only a .statusComplete source is a readable image. An unreadable
        // file with no sidecar throws (counted "skipped", not "had none").
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceGetStatus($0) == .statusComplete ? $0 : nil }
        guard sidecar != nil || source != nil else { throw ReadError.unreadable }

        var out = Extracted()
        if let sidecar { merge(from: sidecar, into: &out) }
        if let source, !out.complete {
            if let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                merge(from: meta, into: &out)
            }
            if !out.complete { mergeIPTC(from: source, into: &out) }
        }
        return out
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
            guard let data = try? Data(contentsOf: candidate),
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
    }
}
