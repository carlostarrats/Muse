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

enum DriveAuthError: Error { case cancelled, badResponse, notSignedIn, refreshFailed }

@MainActor final class GoogleOAuth: NSObject, ObservableObject {
    private let store: TokenStoring
    @Published private(set) var isSignedIn: Bool

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
        isSignedIn = false
    }

    /// A valid access token, refreshing as needed.
    func validAccessToken() async throws -> String {
        guard let tokens = store.load() else { throw DriveAuthError.notSignedIn }
        if tokens.expiry.timeIntervalSinceNow > 60 { return tokens.accessToken }
        return try await refresh(tokens.refreshToken)
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
            .init(name: "prompt", value: "consent"),
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
        guard let json = try? await postForm(DriveConfig.tokenEndpoint, body),
              let access = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Double
        else { store.clear(); isSignedIn = false; throw DriveAuthError.refreshFailed }
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
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw DriveAuthError.badResponse }
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
