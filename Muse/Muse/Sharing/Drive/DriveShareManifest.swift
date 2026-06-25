//
//  DriveShareManifest.swift
//  Muse
//
//  The entire personalization payload for a share, baked (base64url JSON) into
//  the page URL's FRAGMENT so it never reaches the host. Mirrors what share.js
//  decodes. Pure value type.
//

import Foundation

struct DriveShareManifest: Codable, Equatable {
    var intro: String
    var label: String
    var name: String
    var date: String
    var expiry: String      // ISO-8601 yyyy-MM-dd
    var imageIDs: [String]
    var pdfID: String?

    enum CodingKeys: String, CodingKey {
        case intro = "i", label = "l", name = "n", date = "d",
             expiry = "e", imageIDs = "g", pdfID = "p"
    }

    func encoded() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ fragment: String) -> DriveShareManifest? {
        var s = fragment.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s),
              let m = try? JSONDecoder().decode(DriveShareManifest.self, from: data)
        else { return nil }
        return m
    }

    func pageURL(base: String) -> String { "\(base)#\(encoded())" }
}
