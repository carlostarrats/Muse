//
//  XMPGPS.swift
//  Muse
//
//  Coordinates as XMP writes them — the one GPS source `PhotoHeaderReader`
//  structurally cannot reach, because it reads the IMAGE header and a
//  sidecar-only RAW workflow puts the coordinate in the `.xmp` beside the file
//  instead.
//
//  Lightroom writes `exif:GPSLatitude` as "47,20.516N" (degrees, comma,
//  decimal minutes, hemisphere) or occasionally "47,20,31.0N" (degrees,
//  minutes, seconds, hemisphere). Longitude mirrors it with E/W.
//
//  Same fail-closed posture as `PhotoHeaderReader.sanitize`: non-finite or
//  out-of-range is nil, never a pin in the sea.
//

import Foundation

nonisolated enum XMPGPS {

    /// Signed decimal degrees, or nil for anything malformed. The magnitude is
    /// bounded at 180 here (the axis-correct bound is applied by
    /// `coordinate(lat:lon:)`, which knows which axis it is holding).
    static func parse(_ s: String?) -> Double? {
        guard let raw = s?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        // Hemisphere is the final character; without it there is no sign and
        // the string is not an XMP coordinate.
        guard let hemisphere = raw.last, "NSEWnsew".contains(hemisphere) else { return nil }
        let body = String(raw.dropLast())
        let parts = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        var magnitude = 0.0
        var scale = 1.0
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let value = Double(trimmed), value.isFinite, value >= 0 else { return nil }
            magnitude += value * scale
            scale /= 60
        }
        guard magnitude.isFinite, magnitude <= 180 else { return nil }
        let negative = hemisphere == "S" || hemisphere == "s"
            || hemisphere == "W" || hemisphere == "w"
        return negative ? -magnitude : magnitude
    }

    /// Both axes present and each within ITS OWN bound (90 for latitude, 180
    /// for longitude — a single shared bound would let a 150° "latitude"
    /// through), or nil.
    static func coordinate(lat: String?, lon: String?) -> (Double, Double)? {
        guard let latitude = parse(lat), let longitude = parse(lon),
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return (latitude, longitude)
    }
}
