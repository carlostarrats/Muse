//
//  AnnouncementStore.swift
//  Muse
//
//  Its own store object (AppState is frozen). Fetched once per launch; each
//  message shown once, by id. Nothing is sent — a plain GET of a static file on
//  the existing Cloudflare Pages host, on an EPHEMERAL session (no cookies, no
//  persistent cache, no credential store), no query string, no identifiers.
//
//  This is one of the app's three sanctioned app-initiated network paths (Drive
//  share, announcements, and the future custom-domain Worker) — and the only
//  one that isn't user-initiated, which is why it is off-able in Settings and
//  why the setting disables the FETCH, not just the display.
//

import Foundation

@MainActor
final class AnnouncementStore: ObservableObject {
    @Published private(set) var pending: Announcement?

    private static let seenIDsKey = "announcementsSeenIDs"
    /// Bound on the persisted set. Overflowing drops the oldest-known ids;
    /// worst case a very old message is shown twice, which is preferable to
    /// unbounded defaults growth.
    private static let maxSeenIDs = 200

    func fetchIfNeeded() async {
        guard AppSettings.announcementsEnabled else { return }
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = [:]
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        var request = URLRequest(url: CommerceConfig.announcementsURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 10)
        request.httpMethod = "GET"
        // Every failure is silent by design: no feed deployed yet, offline, a
        // 404, a malformed payload — none of them are the user's problem and
        // none of them may produce error UI at launch.
        // Bounded WHILE reading, not after. `AnnouncementFeed.parse` also caps
        // at `maxPayloadBytes`, but that check only runs once the bytes are
        // already in memory — which is no bound at all against a host serving a
        // multi-gigabyte body to the one fetch that happens automatically at
        // every launch. See BoundedBody.
        guard let (data, response) = try? await BoundedBody.data(
                for: request, session: session,
                limit: AnnouncementFeed.maxPayloadBytes),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let feed = AnnouncementFeed.parse(data) else { return }

        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        let unseen = AnnouncementFeed.unseen(feed, seen: loadSeenIDs(), appVersion: appVersion)
        pending = unseen.first
    }

    func dismiss(_ id: String) {
        guard !id.isEmpty else { pending = nil; return }
        var seen = loadSeenIDs()
        seen.insert(id)
        if seen.count > Self.maxSeenIDs {
            seen = Set(seen.prefix(Self.maxSeenIDs))
        }
        UserDefaults.standard.set(Array(seen), forKey: Self.seenIDsKey)
        pending = nil
    }

    private func loadSeenIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.seenIDsKey) ?? [])
    }
}
