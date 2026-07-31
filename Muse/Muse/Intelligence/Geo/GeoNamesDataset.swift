//
//  GeoNamesDataset.swift
//  Muse
//
//  Bundled, offline GeoNames cities1000 dataset + admin1 code table. There is
//  no network here and never will be: CLGeocoder/MapKit geocoding are
//  throttled AND a network call, both disqualifying.
//
//  cities1000 (not cities15000): villages are where travel photos happen.
//
//  The parsed table (~7 MB resident for the full dataset) is NOT cached — the
//  caller holds it for the duration of a geocode pass and it is freed the
//  moment that pass ends, so browsing carries zero standing cost.
//  Regenerate the artifacts with scripts/make-geonames.sh and bump
//  `version`; a version bump re-geocodes the library (pure CPU over DB rows,
//  no file I/O).
//

import Foundation
import Compression

nonisolated struct GeoCity: Sendable {
    let name: String
    let lat: Double
    let lon: Double
    let admin1Code: String   // "PT.14"
    let countryCode: String  // "PT" — ISO 3166-1 alpha-2
}

nonisolated final class GeoNamesDataset: @unchecked Sendable {
    /// Bump when regenerating the bundled artifacts (scripts/make-geonames.sh).
    static let version = 1
    static let shared = GeoNamesDataset()

    /// Sanity ceiling on the declared inflated size. The full cities1000 TSV
    /// is ~9 MB; 64 MB leaves room to grow without ever letting a corrupt
    /// header ask for an unbounded allocation.
    static let maxInflatedBytes = 64_000_000

    private let lock = NSLock()
    private var admin1Cache: [String: String]?

    /// Parsed cities, or nil when the bundled resource is missing/corrupt
    /// (fail closed — geocoding simply doesn't run).
    ///
    /// Deliberately NOT cached: the caller holds the array for the duration of
    /// its pass and the table is freed the moment it lets go. Browsing must
    /// carry no standing cost, and a geocode pass parses this exactly once.
    func cities() -> [GeoCity]? {
        guard let url = Bundle.main.url(forResource: "geonames-cities", withExtension: "tsv.zlib"),
              let raw = try? Data(contentsOf: url) else { return nil }
        return Self.loadCities(from: raw)
    }

    /// The admin1 map is tiny (a few thousand short strings) and is consulted
    /// once per geocoded file, so this one IS cached for the process.
    func admin1Name(for code: String) -> String? {
        lock.lock()
        if admin1Cache == nil {
            lock.unlock()
            let loaded = Self.loadAdmin1() ?? [:]
            lock.lock()
            admin1Cache = loaded
        }
        let value = admin1Cache?[code]
        lock.unlock()
        return value
    }

    /// Bounded decompress: the expected inflated byte count is the first 4
    /// (little-endian) bytes. Allocates exactly that; a short or overflowing
    /// decode is treated as corrupt — fail closed, no crash, no unbounded
    /// allocation. Same contract as the Drive share manifest's inflate cap.
    static func loadCities(from raw: Data) -> [GeoCity]? {
        guard raw.count > 4 else { return nil }
        let declaredSize = raw.prefix(4).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }.littleEndian
        guard declaredSize > 0, Int(declaredSize) <= maxInflatedBytes else { return nil }

        let payload = Data(raw.dropFirst(4))
        var output = [UInt8](repeating: 0, count: Int(declaredSize))
        let decodedCount: Int = output.withUnsafeMutableBytes { outBuf in
            payload.withUnsafeBytes { inBuf -> Int in
                guard let inBase = inBuf.bindMemory(to: UInt8.self).baseAddress,
                      let outBase = outBuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(outBase, outBuf.count,
                                                 inBase, inBuf.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard decodedCount == Int(declaredSize),
              let text = String(bytes: output, encoding: .utf8) else { return nil }

        var cities: [GeoCity] = []
        cities.reserveCapacity(200_000)
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count == 5,
                  let lat = Double(cols[1]), let lon = Double(cols[2]) else { continue }
            cities.append(GeoCity(name: String(cols[0]), lat: lat, lon: lon,
                                  admin1Code: String(cols[3]), countryCode: String(cols[4])))
        }
        return cities.isEmpty ? nil : cities
    }

    private static func loadAdmin1() -> [String: String]? {
        guard let url = Bundle.main.url(forResource: "geonames-admin1", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var map: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count == 2 else { continue }
            map[String(cols[0])] = String(cols[1])
        }
        return map
    }
}
