//
//  CoordinateReader.swift
//  Muse
//
//  Header-only GPS read for the coordinate-persistence pipeline (v13). Mirrors
//  FileMetadata's display-time coordinate/ISO-6709 parsing exactly — it calls
//  the SAME pure functions (`FileMetadata.coordinate(latitude:…)` and
//  `FileMetadata.parseISO6709`), so the two can't diverge into a viewer showing
//  one location while the DB stores another.
//
//  Header-only: no decode, no full-file read. A dataless iCloud placeholder is
//  skipped rather than forced to download, same guard as `FileMetadata.load`
//  and `Indexer.isDataless`.
//

import Foundation
import ImageIO
import AVFoundation

nonisolated enum CoordinateReader {

    static func read(url: URL, kind: AssetKind) async -> Coordinate? {
        switch kind {
        case .image, .raw, .psd:
            return readImageGPS(url: url)
        case .video:
            return await readVideoGPS(url: url)
        default:
            return nil
        }
    }

    /// Rejects non-finite and out-of-range values — a corrupt header must not
    /// put a pin in the sea.
    static func sanitize(_ c: Coordinate) -> Coordinate? {
        guard c.lat.isFinite, c.long.isFinite,
              abs(c.lat) <= 90, abs(c.long) <= 180 else { return nil }
        return c
    }

    // MARK: - Private

    private static func isDataless(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus == .notDownloaded
    }

    private static func readImageGPS(url: URL) -> Coordinate? {
        guard !isDataless(url) else { return nil }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        else { return nil }
        let coord = FileMetadata.coordinate(
            latitude: gps[kCGImagePropertyGPSLatitude] as? Double,
            latRef: gps[kCGImagePropertyGPSLatitudeRef] as? String,
            longitude: gps[kCGImagePropertyGPSLongitude] as? Double,
            longRef: gps[kCGImagePropertyGPSLongitudeRef] as? String)
        return coord.flatMap(sanitize)
    }

    private static func readVideoGPS(url: URL) async -> Coordinate? {
        guard !isDataless(url) else { return nil }
        // Reference-restricted asset — a QuickTime reference movie must never
        // resolve a remote data ref just because we asked for its metadata.
        let asset = AVURLAsset.noNetwork(url: url)
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        for item in metadata where item.commonKey == .commonKeyLocation {
            if let s = try? await item.load(.stringValue),
               let coord = FileMetadata.parseISO6709(s) {
                return sanitize(coord)
            }
        }
        return nil
    }
}
