//
//  ImportSupplement.swift
//  Muse
//
//  The ONE writer for externally-sourced GPS and capture dates — XMP sidecar
//  GPS, Google Takeout JSON, `PHAsset`. A new source is a reader and a mapper;
//  it never gets its own way into `files.lat/lon` or `photo_meta`.
//
//  Merge rule, per field: HEADER WINS, external fills gaps. The file's own
//  header is the more trustworthy source when it has anything to say; the
//  external side exists precisely because Takeout and Photos routinely strip
//  those fields out of the exported bytes.
//
//  Both Spec 02 scan markers are stamped either way. That matters: a supplement
//  IS a completed header scan, and `AnalyzePipeline.writePhotoHeader` skips its
//  write when both markers are already fresh (amendment A1) — which is what
//  stops the next analyze pass from overwriting an imported coordinate with the
//  header's NULL.
//
//  Recorded limitation: an edit-in-place stales the markers, the header is
//  re-read, and supplement-only values drop until the source is re-imported.
//

import Foundation
import GRDB

nonisolated enum ImportSupplement {

    struct External: Equatable, Sendable {
        var lat: Double?
        var lon: Double?
        var captureDate: Int64?

        init(lat: Double? = nil, lon: Double? = nil, captureDate: Int64? = nil) {
            self.lat = lat
            self.lon = lon
            self.captureDate = captureDate
        }

        var isEmpty: Bool { lat == nil && lon == nil && captureDate == nil }
    }

    nonisolated struct AppliedFields: Equatable {
        var coordinates: Bool = false
        var captureDate: Bool = false
    }

    /// Runs inside the caller's `queue.write`. Row-guarded on `content_hash`
    /// still matching — a file re-indexed mid-run must not receive another
    /// file's metadata.
    @discardableResult
    static func apply(db: GRDB.Database, fileID: String, contentHash: String,
                      header: PhotoHeader, external: External) throws -> AppliedFields {
        var applied = AppliedFields()
        guard var file = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db),
              file.content_hash == contentHash else { return applied }

        // (0, 0) is ABSENT, never null island — Takeout and Photos both write
        // it for "we don't know".
        var externalCoordinate: (lat: Double, lon: Double)?
        if let lat = external.lat, let lon = external.lon,
           lat.isFinite, lon.isFinite, !(lat == 0 && lon == 0),
           abs(lat) <= 90, abs(lon) <= 180 {
            externalCoordinate = (lat, lon)
        }

        if let headerCoordinate = header.coordinate.flatMap(PhotoHeaderReader.sanitize) {
            file.lat = headerCoordinate.lat
            file.lon = headerCoordinate.long
        } else if let externalCoordinate {
            file.lat = externalCoordinate.lat
            file.lon = externalCoordinate.lon
            applied.coordinates = true
        }
        file.coords_scanned_hash = contentHash
        try file.update(db)

        var meta = (try PhotoMetaRow.filter(Column("file_id") == fileID).fetchOne(db))
            ?? PhotoMetaRow(file_id: fileID)
        if let exif = header.exif {
            meta.camera_make = exif.cameraMake
            meta.camera_model = exif.cameraModel
            meta.lens = exif.lens
            meta.iso = exif.iso
            meta.f_number = exif.fNumber
            meta.exposure_seconds = exif.exposureSeconds
            meta.focal_length = exif.focalLength
            meta.focal_length_35mm = exif.focalLength35mm
            meta.flash_fired = exif.flashFired
        }
        if let headerDate = header.exif?.captureDate {
            meta.capture_date = headerDate
            meta.capture_md = header.exif?.captureMD ?? monthDay(from: headerDate)
        } else if let externalDate = external.captureDate {
            meta.capture_date = externalDate
            // Derived from the SAME epoch that won, so the two can never disagree.
            meta.capture_md = monthDay(from: externalDate)
            applied.captureDate = true
        }
        meta.exif_scanned_hash = contentHash
        try meta.save(db)
        return applied
    }

    /// "MM-DD" for the materialized on-this-day key, in the local time zone —
    /// the same convention `PhotoHeaderReader` uses for EXIF dates.
    static func monthDay(from epoch: Int64) -> String {
        PhotoHeaderReader.monthDay(Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}
