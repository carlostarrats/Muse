//
//  DriveShareManifest.swift
//  Muse
//
//  The entire personalization payload for a share, baked (base64url JSON) into
//  the page URL's FRAGMENT so it never reaches the host. Mirrors what share.js
//  decodes. Pure value type.
//

import Foundation
import Compression

struct DriveShareManifest: Codable, Equatable {
    var intro: String
    var label: String
    var name: String
    var date: String
    var expiry: String      // ISO-8601 yyyy-MM-dd
    var imageIDs: [String]
    var filenames: [String]? = nil   // key "f"; parallel to imageIDs (optional → old links lack it)
    var pdfID: String?

    enum CodingKeys: String, CodingKey {
        case intro = "i", label = "l", name = "n", date = "d",
             expiry = "e", imageIDs = "g", filenames = "f", pdfID = "p"
    }

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
