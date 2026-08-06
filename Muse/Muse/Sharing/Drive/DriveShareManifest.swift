//
//  DriveShareManifest.swift
//  Muse
//
//  The complete share payload uploaded as manifest.json in the user's Drive.
//  New links put only that file's id in the URL fragment; the legacy
//  base64url/DEFLATE codec remains so links made by older builds still render.
//

import Foundation
import Compression

struct DriveShareManifest: Codable, Equatable {
    var intro: String
    var label: String
    var name: String
    var date: String
    var expiry: String      // ISO-8601 yyyy-MM-dd; "" for portfolio manifests
    var imageIDs: [String]
    var filenames: [String]? = nil   // key "f"; parallel to imageIDs (optional → old links lack it)
    var pdfID: String?
    // Spec 07 v2 keys. Every one is optional with a nil default, so a manifest
    // that uses none of these features encodes with NONE of the new keys present
    // — the wire shape stays byte-identical to the pre-Spec-07 format and legacy
    // fragments keep decoding forever.
    var layout: String? = nil        // key "y" — DriveShareLayout.rawValue; absent = grid
    var bodyText: String? = nil      // key "s" — intro paragraph (essay header / portfolio intro)
    var manifestID: String? = nil    // key "m" — Drive file id of the live manifest.json (portfolio only)
    // A tiny, live layout.json lets the sender change ONLY the page's default
    // layout after sharing. Images/text/expiry remain in manifest.json;
    // recipients can still switch locally without writing anything back.
    var layoutSettingsID: String? = nil // key "u" — Drive file id of layout.json
    var kind: String? = nil          // key "k" — "portfolio" only; absent = expiring share

    enum CodingKeys: String, CodingKey {
        case intro = "i", label = "l", name = "n", date = "d",
             expiry = "e", imageIDs = "g", filenames = "f", pdfID = "p",
             layout = "y", bodyText = "s", manifestID = "m",
             layoutSettingsID = "u", kind = "k"
    }

    /// App-side caps mirroring the page's own validator (share.js MAX_FIELD /
    /// MAX_NAME / the 1000-image grid cap). Enforced at publish time
    /// (`DriveSharePublishGuard`) so the app can never mint a link its own page
    /// rejects as "unavailable".
    static let maxImages = 1000
    static let maxFieldLength = 4096

    // The payload rides the URL fragment, which grows with the image list (and now
    // the filenames). To keep links small we DEFLATE the JSON and prefix a 0x01
    // marker — but only when that's actually smaller than the raw JSON (tiny shares
    // don't benefit). Legacy links are raw JSON (first byte '{'), so the marker
    // lets the page tell them apart. DEFLATE here is raw RFC-1951 (COMPRESSION_ZLIB),
    // which fflate's inflateSync on the page reads (verified cross-language).
    func encoded() -> String {
        let json = (try? JSONEncoder().encode(self)) ?? Data()
        var payload = json
        if let deflated = Self.rawDeflate(json), deflated.count + 1 < json.count {
            payload = Data([0x01]) + deflated
        }
        return payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ fragment: String) -> DriveShareManifest? {
        var s = fragment.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let raw = Data(base64Encoded: s) else { return nil }
        let json: Data
        if raw.first == 0x01 {
            guard let inflated = rawInflate(Data(raw.dropFirst())) else { return nil }
            json = inflated
        } else {
            json = raw
        }
        return try? JSONDecoder().decode(DriveShareManifest.self, from: json)
    }

    func pageURL(base: String) -> String { "\(base)#\(encoded())" }

    /// New links are deliberately short: `r:` plus the public manifest.json
    /// Drive id rides the fragment. The page fetches and validates that manifest; the
    /// file remains a child of the share folder, so Unpublish removes it with
    /// the images and layout.json in one folder deletion.
    static func remotePageURL(manifestID: String, base: String) -> String {
        "\(base)#r:\(manifestID)"
    }

    /// The plain, uncompressed, un-base64'd JSON encoding — the bytes uploaded
    /// as `manifest.json` for every new share.
    func jsonData() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    // Raw DEFLATE (RFC 1951) via Apple's Compression framework — no zlib/gzip
    // wrapper — to match the page's fflate inflateSync.
    private static func rawDeflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let cap = data.count + 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes {
            compression_encode_buffer(dst, cap, $0.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return n > 0 ? Data(bytes: dst, count: n) : nil
    }

    private static func rawInflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let cap = max(data.count * 40, 1 << 20)   // manifests are small; generous headroom
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes {
            compression_decode_buffer(dst, cap, $0.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return n > 0 ? Data(bytes: dst, count: n) : nil
    }
}

/// The three share-page layouts. Raw values ARE the manifest wire values — the
/// page's `layoutOf` must match them exactly (two implementations, one
/// contract; pinned by tests on both sides). An unknown/absent value renders
/// grid on the page, never a rejection.
enum DriveShareLayout: String, CaseIterable, Codable {
    case grid, sheet, essay, stack

    /// The two sender/viewer choices. `sheet` and `essay` stay decodable so a
    /// link made by an intermediate development build still renders safely.
    static let selectable: [DriveShareLayout] = [.grid, .stack]

    var displayName: String {
        switch self {
        case .grid: return String(localized: "Grid")
        case .stack: return String(localized: "Editorial")
        case .sheet: return String(localized: "Contact Sheet")
        case .essay: return String(localized: "Essay")
        }
    }

}

/// The complete contents of the public layout.json sidecar. Deliberately tiny:
/// Manage Shares can change presentation without touching the image manifest.
struct DriveShareLayoutSettings: Codable, Equatable {
    var layout: String

    enum CodingKeys: String, CodingKey { case layout = "y" }

    init(_ layout: DriveShareLayout) { self.layout = layout.rawValue }

    func jsonData() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}
