//
//  BoundedRead.swift
//  Muse
//
//  Size-capped reads for the small metadata files an import walks — XMP
//  sidecars, Takeout `.json`, Eagle's `metadata.json`, `.xmp` presets.
//
//  This is the import-side twin of `ThumbnailCache.withinDecodeBudget`. Every
//  one of these paths reads a file the USER pointed at, and `Data(contentsOf:)`
//  is happy to pull a multi-gigabyte "sidecar" into RAM in full — against
//  "never write code that assumes everything fits in RAM" (DECIDED #25), and
//  reachable by simply pointing an import at the wrong folder. A real sidecar
//  from any of these tools is measured in kilobytes.
//
//  Same shape as the decode budget: a header-cheap check first, and a file
//  that fails it is SKIPPED, never partially read.
//

import Foundation

nonisolated enum BoundedRead {
    /// Generous by three orders of magnitude for every format that uses this.
    static let maxMetadataBytes = 16 * 1024 * 1024

    /// The file's bytes, or nil when it is missing, empty, or larger than the
    /// cap.
    static func metadata(at url: URL, limit: Int = maxMetadataBytes) -> Data? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > 0, size <= limit,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return data
    }
}
