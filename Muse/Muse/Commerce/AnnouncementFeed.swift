//
//  AnnouncementFeed.swift
//  Muse
//
//  Pure parse/selection logic for the announcements channel (DECIDED #28).
//  Nothing is SENT to fetch this — a plain GET of a static file, no query
//  string, no identifiers, no accounts, no tracking.
//
//  Hardened like the Drive share page's manifest, and for the same reason: the
//  payload is attacker-suppliable in principle (anyone who can serve that host,
//  or sit between it and the user). Size-capped BEFORE decode, unknown version
//  values ignored rather than guessed at, every displayed field sanitized and
//  length-capped, https-only urls.
//

import Foundation

struct Announcement: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let body: String
    let url: String?
    let minAppVersion: String?
}

struct AnnouncementFeed: Codable, Equatable, Sendable {
    let version: Int
    let messages: [Announcement]
}

extension AnnouncementFeed {
    /// Cap applied before JSONDecoder ever sees the bytes — same class of guard
    /// as the share manifest's MAX_INFLATED.
    static let maxPayloadBytes = 64 * 1024
    static let currentVersion = 1
    static let maxTitleLength = 200
    static let maxBodyLength = 2000
    static let maxIDLength = 100

    static func parse(_ data: Data) -> AnnouncementFeed? {
        guard data.count <= maxPayloadBytes else { return nil }
        guard let raw = try? JSONDecoder().decode(AnnouncementFeed.self, from: data) else { return nil }
        // An unknown version means fields we don't understand — show nothing
        // rather than render a guess.
        guard raw.version == currentVersion else { return nil }
        let cleaned = raw.messages.compactMap { m -> Announcement? in
            guard !m.id.isEmpty, m.id.count <= maxIDLength else { return nil }
            let safeURL: String? = m.url.flatMap { urlString in
                // https only: a message is a link the user is invited to open,
                // and http (or file:, or a custom scheme) has no place there.
                guard let u = URL(string: urlString), u.scheme == "https" else { return nil }
                return urlString
            }
            return Announcement(
                id: m.id,
                title: AnnouncementSanitizer.strip(m.title, maxLength: maxTitleLength),
                body: AnnouncementSanitizer.strip(m.body, maxLength: maxBodyLength),
                url: safeURL,
                minAppVersion: m.minAppVersion)
        }
        return AnnouncementFeed(version: raw.version, messages: cleaned)
    }

    /// Messages not yet shown on this machine and applicable to this build.
    /// `.numeric` compare orders multi-digit segments correctly ("1.10" > "1.6").
    static func unseen(_ feed: AnnouncementFeed, seen: Set<String>,
                       appVersion: String) -> [Announcement] {
        feed.messages.filter { msg in
            guard !seen.contains(msg.id) else { return false }
            if let minVersion = msg.minAppVersion,
               minVersion.compare(appVersion, options: .numeric) == .orderedDescending {
                return false
            }
            return true
        }
    }
}

/// Strips the characters that let remote text lie about itself: bidi overrides
/// and isolates (which can reverse displayed text), zero-width characters
/// (invisible padding), and control characters. Same anti-spoofing intent as
/// the share page's `sanitizeText`, which is JS-side — this feed is parsed
/// in-app, so it needs its own.
enum AnnouncementSanitizer {
    private static let stripSet: CharacterSet = {
        var set = CharacterSet()
        for scalar in 0x202A...0x202E { set.insert(UnicodeScalar(scalar)!) }  // bidi overrides
        for scalar in 0x2066...0x2069 { set.insert(UnicodeScalar(scalar)!) }  // bidi isolates
        for scalar in 0x200B...0x200D { set.insert(UnicodeScalar(scalar)!) }  // zero-width
        set.insert(UnicodeScalar(0xFEFF)!)                                    // BOM / ZWNBSP
        set.formUnion(.controlCharacters)
        return set
    }()

    static func strip(_ s: String, maxLength: Int) -> String {
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter { !stripSet.contains($0) }))
        return String(cleaned.prefix(maxLength))
    }
}
