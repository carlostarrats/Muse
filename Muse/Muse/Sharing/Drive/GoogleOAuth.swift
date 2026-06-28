//
//  GoogleOAuth.swift
//  Muse
//
//  Google OAuth 2.0 Authorization Code + PKCE for a sandboxed native app.
//  ASWebAuthenticationSession (system browser), no client secret. Tokens go
//  straight to Keychain via TokenStore; access tokens refreshed on demand.
//

import Foundation
import AppKit
import AuthenticationServices

enum DriveAuthError: Error { case cancelled, badResponse, notSignedIn, refreshFailed, invalidGrant }

@MainActor final class GoogleOAuth: NSObject, ObservableObject {
    private let store: TokenStoring
    @Published private(set) var isSignedIn: Bool
    /// In-flight token refresh, shared by concurrent callers. The first caller
    /// starts it; the rest await the same task instead of each firing their own
    /// refresh round-trip (which, with a rotating-refresh-token IdP, could let
    /// one refresh invalidate another's token). Cleared when it settles.
    private var inFlightRefresh: Task<String, Error>?

    init(store: TokenStoring = KeychainTokenStore()) {
        self.store = store
        self.isSignedIn = store.load() != nil
    }

    func signOut() async {
        if let t = store.load() {
            // Best-effort revoke. The token goes in the POST BODY (never the URL
            // — secrets in URLs leak via logs/history/referrer).
            var req = URLRequest(url: URL(string: DriveConfig.revokeEndpoint)!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let encoded = t.refreshToken.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? t.refreshToken
            req.httpBody = "token=\(encoded)&token_type_hint=refresh_token".data(using: .utf8)
            _ = try? await URLSession.shared.data(for: req)
        }
        store.clear()
        // The remembered Muse-root folder belongs to the OLD account — drop it
        // so the next account gets a fresh "Muse" folder (drive.file can't see
        // the previous account's folder anyway).
        AppSettings.driveRootFolderID = nil
        isSignedIn = false
    }

    /// A valid access token, refreshing as needed.
    func validAccessToken() async throws -> String {
        guard let tokens = store.load() else { throw DriveAuthError.notSignedIn }
        if tokens.expiry.timeIntervalSinceNow > 60 { return tokens.accessToken }
        // Coalesce: if a refresh is already running, await it rather than firing
        // a second. The check + assignment below run without an `await` between
        // them (MainActor), so only the first caller creates the task.
        if let inFlight = inFlightRefresh { return try await inFlight.value }
        let refreshToken = tokens.refreshToken
        let task = Task<String, Error> { try await self.refresh(refreshToken) }
        inFlightRefresh = task
        do {
            let token = try await task.value
            inFlightRefresh = nil
            return token
        } catch {
            inFlightRefresh = nil
            throw error
        }
    }

    func signIn() async throws {
        let verifier = PKCE.verifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.randomState()
        var comps = URLComponents(string: DriveConfig.authEndpoint)!
        comps.queryItems = [
            .init(name: "client_id", value: DriveConfig.clientID),
            .init(name: "redirect_uri", value: DriveConfig.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: DriveConfig.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            // select_account → always show the chooser (lets the user switch
            // personal↔business); consent → guarantees a refresh token.
            .init(name: "prompt", value: "select_account consent"),
        ]
        let callback = try await authenticate(url: comps.url!,
                                              scheme: DriveConfig.redirectScheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value
        else { throw DriveAuthError.badResponse }
        try await exchange(code: code, verifier: verifier)
        isSignedIn = true
    }

    // MARK: token endpoints

    private func exchange(code: String, verifier: String) async throws {
        let body = [
            "client_id": DriveConfig.clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": DriveConfig.redirectURI,
            "grant_type": "authorization_code",
        ]
        let json = try await postForm(DriveConfig.tokenEndpoint, body)
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Double
        else { throw DriveAuthError.badResponse }
        store.save(DriveTokens(accessToken: access, refreshToken: refresh,
                               expiry: Date().addingTimeInterval(expiresIn)))
    }

    private func refresh(_ refreshToken: String) async throws -> String {
        let body = [
            "client_id": DriveConfig.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        let json: [String: Any]
        do {
            json = try await postForm(DriveConfig.tokenEndpoint, body)
        } catch DriveAuthError.invalidGrant {
            // The refresh token is DEFINITIVELY dead (revoked / expired / account
            // changed). Only here do we drop credentials and force re-sign-in.
            store.clear(); isSignedIn = false
            throw DriveAuthError.refreshFailed
        }
        // Any other failure (network drop, 5xx, malformed body) propagates as a
        // transient throw WITHOUT clearing the still-valid refresh token — a flaky
        // connection must not silently sign the user out.
        guard let access = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Double
        else { throw DriveAuthError.badResponse }
        // Google may not re-send the refresh token; keep the existing one.
        store.save(DriveTokens(accessToken: access, refreshToken: refreshToken,
                               expiry: Date().addingTimeInterval(expiresIn)))
        return access
    }

    private func postForm(_ endpoint: String, _ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let json else {
            // Surface a definitively-dead grant distinctly so the refresh path can
            // tell "token revoked/expired" (clear + re-auth) from a transient
            // network/server failure (keep the token, retry later).
            if let err = json?["error"] as? String, err == "invalid_grant" {
                throw DriveAuthError.invalidGrant
            }
            throw DriveAuthError.badResponse
        }
        return json
    }

    // MARK: ASWebAuthenticationSession

    private func authenticate(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback { cont.resume(returning: callback) }
                else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    cont.resume(throwing: DriveAuthError.cancelled)
                } else { cont.resume(throwing: error ?? DriveAuthError.badResponse) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }
}

extension GoogleOAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }
}
