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
    /// rides the URL fragment, so the page link is `<shareBaseURL>#<payload>`.
    static let shareBaseURL = "https://muse-share.pages.dev"

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
