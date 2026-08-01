//
//  TakeoutJSON.swift
//  Muse
//
//  Google Takeout's per-photo JSON sidecar, and the ladder that finds it.
//
//  Google's edits are server-side and unrecoverable, so an import is exactly
//  this: the JSON's metadata (which Takeout frequently STRIPS from the image
//  files themselves — dates and GPS in particular) merged onto ordinary files
//  that stay where they are. The edited JPEG simply IS the picture.
//
//  The filename ladder is the fiddly part. Takeout has changed its convention
//  several times and mangles names in several documented ways; each rule below
//  is its own tested case.
//

import Foundation

nonisolated struct TakeoutMeta: Equatable, Sendable {
    var photoTakenTime: Int64?
    var lat: Double?
    var lon: Double?
    var description: String?
    var favorited: Bool = false
    var people: [String] = []

    var isEmpty: Bool {
        photoTakenTime == nil && lat == nil && lon == nil
            && description == nil && !favorited && people.isEmpty
    }
}

nonisolated enum TakeoutJSON {

    /// Localized "-edited" suffixes Google appends to a rendered copy. Google
    /// writes ONE json, named for the original, so an edited sibling only finds
    /// its metadata by stripping this.
    static let editedSuffixes = [
        "-edited", "-bearbeitet", "-modifié", "-modificado", "-editado",
        "-bewerkt", "-redigerad", "-muokattu", "-redigeret",
    ]

    /// Takeout truncates the JSON's base name at this many characters.
    static let truncationLimit = 46

    /// Sidecar filenames to try, best-first. Every entry is a plain filename —
    /// the caller checks each as a sibling of the media file.
    static func jsonCandidates(for mediaName: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ name: String) {
            guard !name.isEmpty, seen.insert(name).inserted else { return }
            out.append(name)
        }

        func direct(_ full: String) {
            // 1 — current format. 2 — older format.
            add(full + ".supplemental-metadata.json")
            add(full + ".json")
            // 5 — Takeout truncates the base name; re-derive the short form.
            if full.count > truncationLimit {
                let truncated = String(full.prefix(truncationLimit))
                add(truncated + ".supplemental-metadata.json")
                add(truncated + ".json")
            }
        }

        direct(mediaName)

        // 3 — duplicate-counter swap: "IMG(1).jpg" ↔ "IMG.jpg(1).json".
        if let counter = duplicateCounter(in: mediaName) {
            add(counter.base + "(\(counter.index)).json")
            add(counter.base + ".supplemental-metadata(\(counter.index)).json")
        }

        // 4 — edited-suffix strip: the edited copy borrows the original's JSON.
        if let stripped = strippingEditedSuffix(mediaName) {
            direct(stripped)
            if let counter = duplicateCounter(in: stripped) {
                add(counter.base + "(\(counter.index)).json")
            }
        }
        return out
    }

    /// "IMG(1).jpg" → (base: "IMG.jpg", index: 1).
    private static func duplicateCounter(in name: String) -> (base: String, index: Int)? {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        guard stem.hasSuffix(")"), let open = stem.lastIndex(of: "(") else { return nil }
        let digits = stem[stem.index(after: open)..<stem.index(before: stem.endIndex)]
        guard !digits.isEmpty, let index = Int(digits) else { return nil }
        let base = String(stem[stem.startIndex..<open])
        guard !base.isEmpty else { return nil }
        return (ext.isEmpty ? base : base + "." + ext, index)
    }

    /// "IMG_0001-edited.jpg" → "IMG_0001.jpg".
    private static func strippingEditedSuffix(_ name: String) -> String? {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for suffix in editedSuffixes where stem.lowercased().hasSuffix(suffix) {
            let base = String(stem.dropLast(suffix.count))
            guard !base.isEmpty else { return nil }
            return ext.isEmpty ? base : base + "." + ext
        }
        return nil
    }

    /// Tolerant of every missing key — a Takeout JSON's shape has drifted across
    /// years of exports and a missing field is normal, not an error.
    static func parse(_ data: Data) -> TakeoutMeta? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        var meta = TakeoutMeta()

        // `photoTakenTime.timestamp` is a STRING epoch, not a number.
        if let taken = dict["photoTakenTime"] as? [String: Any] {
            if let s = taken["timestamp"] as? String { meta.photoTakenTime = Int64(s) }
            else if let n = taken["timestamp"] as? NSNumber { meta.photoTakenTime = n.int64Value }
        }

        // geoData first, geoDataExif as the fallback. (0, 0) is ABSENT, never
        // null island — the same rule the supplement writer enforces.
        for key in ["geoData", "geoDataExif"] {
            guard meta.lat == nil,
                  let geo = dict[key] as? [String: Any],
                  let lat = (geo["latitude"] as? NSNumber)?.doubleValue,
                  let lon = (geo["longitude"] as? NSNumber)?.doubleValue,
                  lat.isFinite, lon.isFinite,
                  !(lat == 0 && lon == 0),
                  abs(lat) <= 90, abs(lon) <= 180
            else { continue }
            meta.lat = lat
            meta.lon = lon
        }

        if let raw = dict["description"] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { meta.description = trimmed }
        }
        meta.favorited = (dict["favorited"] as? Bool) ?? false
        if let people = dict["people"] as? [[String: Any]] {
            meta.people = people.compactMap {
                let name = ($0["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return name.isEmpty ? nil : name
            }
        }
        return meta
    }
}
