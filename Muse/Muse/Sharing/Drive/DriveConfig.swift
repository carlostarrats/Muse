//
//  DriveConfig.swift
//  Muse
//
//  Owner-provided Google OAuth + hosting constants. The CLIENT_ID and domain
//  are filled once the OAuth client + Cloudflare domain exist (see
//  web/share/README.md). No secret here — PKCE public client.
//

import Foundation

enum DriveConfig {
    /// Google OAuth client id (iOS/macOS type). Format: NNN-xxxx.apps.googleusercontent.com
    static let clientID = "572618611419-tpnrrjdskcfknc1157em3bamudbu9pt7.apps.googleusercontent.com"

    /// Reverse-client-id custom scheme Google uses for native redirects.
    static var redirectScheme: String {
        let id = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(id)"
    }
    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    /// Cloudflare Pages deployment serving web/share/index.html. The manifest
    /// is addressed by a short fragment, so the link is `<shareBaseURL>#r:<id>`.
    ///
    /// Changing this only affects links minted from here on. Every link already
    /// sent is `https://muse-share.pages.dev/#…`, and it keeps working because
    /// Cloudflare serves a project's `.pages.dev` subdomain alongside any custom
    /// domain — so **the muse-share Pages project must never be deleted**, or
    /// every share anyone has ever sent dies with it.
    nonisolated static let shareBaseURL = "https://share.muse-photo.com"

    /// Validate a locally stored Manage-Shares URL before handing it to
    /// NSWorkspace. A string-prefix check would also accept lookalike hosts such
    /// as `share.muse-photo.com.evil.example` or an `@evil.example` user-info
    /// URL. Both new short links and legacy inline fragments are allowed, but
    /// only on the exact HTTPS share origin.
    nonisolated static func openableShareURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "share.muse-photo.com",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil,
              parts.path.isEmpty || parts.path == "/",
              let fragment = parts.fragment, fragment.isEmpty == false
        else { return nil }
        return url
    }

    static let scope = "https://www.googleapis.com/auth/drive.file"

    static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    static let revokeEndpoint = "https://oauth2.googleapis.com/revoke"

    /// Set true by the owner once Google's OAuth verification review completes.
    /// A compiled constant, not a Settings key — it describes the DEVELOPER's
    /// console state, not a user preference. While false, the sign-in surfaces
    /// (the publish-sheet explainer and the Settings Drive section) show a short
    /// note that Google may present an "unverified app" interstitial.
    static let consentScreenVerified = false
}
