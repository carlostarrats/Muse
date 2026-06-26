# Google Drive Collection Share Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a collection as a branded, self-expiring Cloudflare-hosted web page whose images live in the user's own Google Drive — sign in once, fill a form, press Publish, get a link; plus a print-quality PDF, View-menu management, and Muse-local expiry deletion.

**Architecture:** A macOS Swift feature (OAuth PKCE → Keychain tokens → Drive REST client → publish orchestrator → expiry sweeper → SwiftUI form/progress/manage sheets) and a self-contained static web page (`web/share/`) that renders entirely from a base64url manifest in the URL **fragment** (no backend, no API key). The page pulls images from Drive's public thumbnail endpoint.

**Tech Stack:** Swift, SwiftUI, AppKit, `AuthenticationServices` (`ASWebAuthenticationSession`), `Security` (Keychain), `CryptoKit` (PKCE S256), `URLSession` (Drive REST), `CollectionPDFExporter` (existing); HTML/CSS/vanilla JS on Cloudflare Pages; XCTest + Node for JS unit tests.

## Global Constraints

- **Min macOS 14.6.** `ASWebAuthenticationSession` + `CryptoKit` + `URLSession` all available.
- **Least privilege:** OAuth scope is EXACTLY `https://www.googleapis.com/auth/drive.file`. Never request `drive` or `drive.readonly`.
- **No client secret in the app.** Authorization Code + **PKCE (S256)**, public client, custom-scheme redirect.
- **Tokens live ONLY in Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synced). Never UserDefaults, never logged.
- **TLS only.** All Google hosts over HTTPS. No ATS exceptions added.
- **Network ONLY inside an explicit user action** (publish / manage / sign-in / a sweep that has expired records + a token). No speculative calls. This is the ONLY network path besides Sparkle.
- **The web page gets NO secrets and NO API key.** Manifest rides the URL **fragment** (`#…`) so it never reaches Cloudflare. All manifest text rendered via `textContent`; ids regex-validated; strict CSP.
- **Files never deleted except folders Muse created in Drive** (the share folders), removed via the Drive API. Never touch the user's other Drive content (drive.file enforces this anyway).
- **New `.swift` files auto-include** via the project's synchronized file groups — no `project.pbxproj` editing. App code under `Muse/Muse/Sharing/Drive/`, tests under `Muse/MuseTests/`, web under `web/share/`.
- **Every new app user-facing string localized** (`String(localized:)`; the app ships French). Run `-exportLocalizations`, fill `fr`.
- **Share set = the collection's currently displayed members** (`appState.visibleFiles`, folders excluded) — same rule as the PDF/iCloud share.
- **Build:** `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -5`
- **Test one class:** `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/<ClassName> 2>&1 | tail -15`
- **JS tests:** `node web/share/share.test.mjs`

## Owner prerequisites (gate runtime, not the build)

Tracked in `web/share/README.md` + `DriveConfig.swift` placeholders. The code builds and pure-unit-tests pass without them; sign-in won't function until they exist: a Google OAuth client (iOS/macOS type, `drive.file`), a Cloudflare custom domain for the page, and a published privacy policy + Google verification.

---

## Phase 1 — Auth foundation

### Task 1: PKCE + state helpers (pure)

**Files:**
- Create: `Muse/Muse/Sharing/Drive/PKCE.swift`
- Test: `Muse/MuseTests/PKCETests.swift`

**Interfaces:**
- Produces: `enum PKCE` — `static func verifier() -> String`, `static func challenge(for verifier: String) -> String`, `static func randomState() -> String`. All base64url, no padding.

- [ ] **Step 1: Write the failing test**

```swift
//  PKCETests.swift
import XCTest
import CryptoKit
@testable import Muse

final class PKCETests: XCTestCase {
    func testVerifierIsBase64URLAndLongEnough() {
        let v = PKCE.verifier()
        XCTAssertGreaterThanOrEqual(v.count, 43)
        XCTAssertLessThanOrEqual(v.count, 128)
        // base64url alphabet only (no +, /, =).
        XCTAssertNil(v.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testChallengeIsS256OfVerifier() {
        let v = "test-verifier-fixed-string-1234567890abcd"
        let expected = Data(SHA256.hash(data: Data(v.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(PKCE.challenge(for: v), expected)
    }

    func testStateIsNonEmptyAndUnique() {
        XCTAssertNotEqual(PKCE.randomState(), PKCE.randomState())
        XCTAssertFalse(PKCE.randomState().isEmpty)
    }
}
```

- [ ] **Step 2: Run test, expect FAIL** (`cannot find 'PKCE'`).
Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/PKCETests 2>&1 | tail -15`

- [ ] **Step 3: Implement**

```swift
//  PKCE.swift
//  Muse
//
//  RFC 7636 PKCE (S256) + state for the Google OAuth flow. Pure crypto, no I/O.
//

import Foundation
import CryptoKit

enum PKCE {
    /// 32 random bytes → base64url (43 chars), the RFC-recommended verifier.
    static func verifier() -> String { base64url(randomBytes(32)) }

    /// base64url( SHA256( verifier ) ) — the S256 challenge.
    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomState() -> String { base64url(randomBytes(16)) }

    private static func randomBytes(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes)
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

- [ ] **Step 4: Run test, expect PASS.**
- [ ] **Step 5: Commit** `feat: PKCE S256 + state helpers for Drive OAuth`.

---

### Task 2: Keychain token store

**Files:**
- Create: `Muse/Muse/Sharing/Drive/TokenStore.swift`
- Test: `Muse/MuseTests/TokenStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct DriveTokens: Codable, Equatable` — `accessToken: String`, `refreshToken: String`, `expiry: Date`.
  - `protocol TokenStoring { func load() -> DriveTokens?; func save(_:); func clear() }`
  - `final class KeychainTokenStore: TokenStoring` (real, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
  - `final class InMemoryTokenStore: TokenStoring` (tests).

- [ ] **Step 1: Write the failing test** (uses the in-memory store — Keychain isn't unit-tested in CI):

```swift
//  TokenStoreTests.swift
import XCTest
@testable import Muse

final class TokenStoreTests: XCTestCase {
    func testRoundTripAndClear() {
        let store: TokenStoring = InMemoryTokenStore()
        XCTAssertNil(store.load())
        let t = DriveTokens(accessToken: "a", refreshToken: "r",
                            expiry: Date(timeIntervalSince1970: 1000))
        store.save(t)
        XCTAssertEqual(store.load(), t)
        store.clear()
        XCTAssertNil(store.load())
    }
}
```

- [ ] **Step 2: Run test, expect FAIL.**
- [ ] **Step 3: Implement**

```swift
//  TokenStore.swift
//  Muse
//
//  Google OAuth tokens live ONLY here — Keychain, device-only, never synced,
//  never logged. A protocol so the orchestrator is testable with an in-memory
//  double (Keychain itself is integration-only).
//

import Foundation
import Security

struct DriveTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
}

protocol TokenStoring: AnyObject {
    func load() -> DriveTokens?
    func save(_ tokens: DriveTokens)
    func clear()
}

final class InMemoryTokenStore: TokenStoring {
    private var tokens: DriveTokens?
    func load() -> DriveTokens? { tokens }
    func save(_ tokens: DriveTokens) { self.tokens = tokens }
    func clear() { tokens = nil }
}

final class KeychainTokenStore: TokenStoring {
    private let service = "com.tarrats.Muse.googleDrive"
    private let account = "oauth-tokens"

    func load() -> DriveTokens? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let tokens = try? JSONDecoder().decode(DriveTokens.self, from: data)
        else { return nil }
        return tokens
    }

    func save(_ tokens: DriveTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    func clear() {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
    }
}
```

- [ ] **Step 4: Run test, expect PASS.**
- [ ] **Step 5: Commit** `feat: Keychain-backed Drive token store (device-only)`.

---

### Task 3: DriveConfig + OAuth client (integration; build-verified)

**Files:**
- Create: `Muse/Muse/Sharing/Drive/DriveConfig.swift`
- Create: `Muse/Muse/Sharing/Drive/GoogleOAuth.swift`
- Modify: `Muse/Muse/Info.plist` (register the reverse-client-id URL scheme)

**Interfaces:**
- Produces:
  - `enum DriveConfig` — `clientID`, `redirectScheme`, `redirectURI`, `shareBaseURL`, `scope` (placeholders the owner fills).
  - `@MainActor final class GoogleOAuth` — `var isSignedIn: Bool`, `func signIn() async throws`, `func signOut() async`, `func validAccessToken() async throws -> String` (refreshes if `expiry` near). `enum DriveAuthError: Error`.

- [ ] **Step 1: Implement DriveConfig (placeholders)**

```swift
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
    static let clientID = "REPLACE_WITH_GOOGLE_OAUTH_CLIENT_ID.apps.googleusercontent.com"

    /// Reverse-client-id custom scheme Google uses for native redirects.
    static var redirectScheme: String {
        // com.googleusercontent.apps.NNN-xxxx  (clientID minus the trailing host)
        let id = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(id)"
    }
    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    /// Cloudflare Pages custom domain serving web/share/index.html at /s.
    static let shareBaseURL = "https://share.example.com/s"

    static let scope = "https://www.googleapis.com/auth/drive.file"

    static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    static let revokeEndpoint = "https://oauth2.googleapis.com/revoke"
}
```

- [ ] **Step 2: Implement GoogleOAuth**

```swift
//  GoogleOAuth.swift
//  Muse
//
//  Google OAuth 2.0 Authorization Code + PKCE for a sandboxed native app.
//  ASWebAuthenticationSession (system browser), no client secret. Tokens go
//  straight to Keychain via TokenStore; access tokens refreshed on demand.
//

import Foundation
import AuthenticationServices

enum DriveAuthError: Error { case cancelled, badResponse, notSignedIn, refreshFailed }

@MainActor final class GoogleOAuth: NSObject, ObservableObject {
    private let store: TokenStoring
    private var presentationAnchor: ASPresentationAnchor?
    @Published private(set) var isSignedIn: Bool

    init(store: TokenStoring = KeychainTokenStore()) {
        self.store = store
        self.isSignedIn = store.load() != nil
    }

    func signOut() async {
        if let t = store.load() {
            // Best-effort revoke; ignore network failure.
            var req = URLRequest(url: URL(string: "\(DriveConfig.revokeEndpoint)?token=\(t.refreshToken)")!)
            req.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: req)
        }
        store.clear()
        isSignedIn = false
    }

    /// A valid access token, refreshing (or signing in) as needed.
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
```

- [ ] **Step 3: Register the URL scheme in Info.plist**

Add to `Muse/Muse/Info.plist` (inside the top `<dict>`). Because the scheme derives from the client id, the actual reverse-client-id string is filled when the owner sets `DriveConfig.clientID`:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>com.tarrats.Muse.googleoauth</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>com.googleusercontent.apps.REPLACE_WITH_REVERSE_CLIENT_ID</string>
        </array>
    </dict>
</array>
```

- [ ] **Step 4: Build, expect BUILD SUCCEEDED.**
Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -5`

- [ ] **Step 5: Commit** `feat: Google OAuth (PKCE, ASWebAuthenticationSession) + DriveConfig`.

---

## Phase 2 — Drive REST client

### Task 4: DriveClient

**Files:**
- Create: `Muse/Muse/Sharing/Drive/DriveClient.swift`
- Test: `Muse/MuseTests/DriveMultipartTests.swift` (the pure multipart-body builder)

**Interfaces:**
- Consumes: `GoogleOAuth.validAccessToken()`.
- Produces: `@MainActor final class DriveClient` with:
  - `func ensureMuseRoot() async throws -> String` (folder id; create-or-reuse via a stored id passed in)
  - `func createFolder(name: String, parent: String) async throws -> String`
  - `func uploadFile(url: URL, name: String, mime: String, parent: String) async throws -> String`
  - `func setAnyoneReader(fileID: String) async throws`
  - `func deleteFolder(id: String) async throws`
  - `func folderExists(id: String) async throws -> Bool`
  - `static func multipartBody(metadata: [String:Any], fileData: Data, mime: String, boundary: String) -> Data` (pure; tested)
  - `enum DriveError: Error { case http(Int), badResponse, notFound }`

- [ ] **Step 1: Write the failing test (pure multipart builder)**

```swift
//  DriveMultipartTests.swift
import XCTest
@testable import Muse

final class DriveMultipartTests: XCTestCase {
    func testMultipartBodyHasBothPartsAndBoundary() {
        let body = DriveClient.multipartBody(
            metadata: ["name": "a.jpg"], fileData: Data([0xFF, 0xD8]),
            mime: "image/jpeg", boundary: "BNDRY")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("--BNDRY"))
        XCTAssertTrue(text.contains("application/json"))
        XCTAssertTrue(text.contains("\"name\":\"a.jpg\"") || text.contains("\"name\": \"a.jpg\""))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg"))
        XCTAssertTrue(text.hasSuffix("--BNDRY--\r\n"))
    }
}
```

- [ ] **Step 2: Run test, expect FAIL.**
- [ ] **Step 3: Implement DriveClient**

```swift
//  DriveClient.swift
//  Muse
//
//  Minimal Google Drive v3 REST client over URLSession — exactly the calls the
//  share flow needs, scoped to drive.file (only files Muse created). Every call
//  carries a fresh access token from GoogleOAuth. TLS-only by construction.
//

import Foundation

@MainActor final class DriveClient {
    enum DriveError: Error { case http(Int), badResponse, notFound }

    private let auth: GoogleOAuth
    init(auth: GoogleOAuth) { self.auth = auth }

    private let filesEndpoint = "https://www.googleapis.com/drive/v3/files"
    private let uploadEndpoint = "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id"

    // MARK: folders

    func createFolder(name: String, parent: String) async throws -> String {
        let meta: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parent],
        ]
        return try await postJSON(filesEndpoint + "?fields=id", meta)
    }

    /// Reuse the stored Muse-root id if it still exists, else create a new one
    /// under My Drive root. (drive.file can't *find* a pre-existing folder it
    /// didn't create, so the caller persists the returned id.)
    func ensureMuseRoot(existingID: String?) async throws -> String {
        if let id = existingID, (try? await folderExists(id: id)) == true { return id }
        return try await createFolder(name: "Muse", parent: "root")
    }

    func folderExists(id: String) async throws -> Bool {
        var req = try await authed("\(filesEndpoint)/\(id)?fields=id,trashed")
        req.httpMethod = "GET"
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return false }
        guard code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw DriveError.http(code) }
        return (json["trashed"] as? Bool) != true
    }

    func deleteFolder(id: String) async throws {
        var req = try await authed("\(filesEndpoint)/\(id)")
        req.httpMethod = "DELETE"
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 204 || code == 200 || code == 404 else { throw DriveError.http(code) }
    }

    // MARK: files

    func uploadFile(url: URL, name: String, mime: String, parent: String) async throws -> String {
        let data = try Data(contentsOf: url)
        let boundary = "muse-\(UUID().uuidString)"
        var req = try await authed(uploadEndpoint)
        req.httpMethod = "POST"
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(
            metadata: ["name": name, "parents": [parent]],
            fileData: data, mime: mime, boundary: boundary)
        let (respData, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let id = json["id"] as? String
        else { throw DriveError.http(code) }
        return id
    }

    func setAnyoneReader(fileID: String) async throws {
        var req = try await authed("\(filesEndpoint)/\(fileID)/permissions")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["role": "reader", "type": "anyone"])
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw DriveError.http(code) }
    }

    // MARK: helpers

    /// Pure multipart/related body: JSON metadata part + raw file part.
    static func multipartBody(metadata: [String: Any], fileData: Data,
                              mime: String, boundary: String) -> Data {
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        let metaJSON = (try? JSONSerialization.data(withJSONObject: metadata)) ?? Data("{}".utf8)
        append("--\(boundary)\r\n")
        append("Content-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metaJSON); append("\r\n")
        append("--\(boundary)\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(fileData); append("\r\n")
        append("--\(boundary)--\r\n")
        return body
    }

    private func postJSON(_ endpoint: String, _ object: [String: Any]) async throws -> String {
        var req = try await authed(endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: object)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String
        else { throw DriveError.http(code) }
        return id
    }

    private func authed(_ urlString: String) async throws -> URLRequest {
        let token = try await auth.validAccessToken()
        var req = URLRequest(url: URL(string: urlString)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
}
```

- [ ] **Step 4: Run test, expect PASS; then build, expect BUILD SUCCEEDED.**
- [ ] **Step 5: Commit** `feat: Drive v3 REST client (folders, multipart upload, permissions)`.

---

## Phase 3 — Manifest, expiry, store

### Task 5: DriveShareManifest (URL fragment payload)

**Files:**
- Create: `Muse/Muse/Sharing/Drive/DriveShareManifest.swift`
- Test: `Muse/MuseTests/DriveShareManifestTests.swift`

**Interfaces:**
- Produces:
  - `struct DriveShareManifest: Codable, Equatable` — `intro: String`, `label: String`, `name: String`, `date: String`, `expiry: String` (ISO-8601 date), `imageIDs: [String]`, `pdfID: String?`.
  - `func encoded() -> String` (base64url JSON, no padding)
  - `static func decode(_ fragment: String) -> DriveShareManifest?`
  - `func pageURL(base: String) -> String` (`<base>#<encoded>`)

- [ ] **Step 1: Write the failing test**

```swift
//  DriveShareManifestTests.swift
import XCTest
@testable import Muse

final class DriveShareManifestTests: XCTestCase {
    private let sample = DriveShareManifest(
        intro: "Leslie-Ann Thomson ALDO MUAH 2025", label: "Sent by",
        name: "The Project", date: "2026-04-01", expiry: "2026-04-04",
        imageIDs: ["aaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbb"], pdfID: "cccccccccccccccccccc")

    func testRoundTripThroughBase64URL() {
        let encoded = sample.encoded()
        XCTAssertNil(encoded.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertEqual(DriveShareManifest.decode(encoded), sample)
    }

    func testPageURLUsesFragment() {
        let url = sample.pageURL(base: "https://share.example.com/s")
        XCTAssertTrue(url.hasPrefix("https://share.example.com/s#"))
        XCTAssertEqual(DriveShareManifest.decode(String(url.split(separator: "#")[1])), sample)
    }

    func testDecodeRejectsGarbage() {
        XCTAssertNil(DriveShareManifest.decode("not-valid-base64url!!"))
    }
}
```

- [ ] **Step 2: Run test, expect FAIL.**
- [ ] **Step 3: Implement**

```swift
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
```

- [ ] **Step 4: Run test, expect PASS.**
- [ ] **Step 5: Commit** `feat: Drive share manifest (base64url URL-fragment payload)`.

---

### Task 6: Expiry decision + share record store

**Files:**
- Create: `Muse/Muse/Sharing/Drive/DriveShareRecord.swift`
- Test: `Muse/MuseTests/DriveShareStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct DriveShareRecord: Codable, Identifiable, Equatable` — `id: String`, `collectionName: String`, `folderID: String`, `pageURL: String`, `itemCount: Int`, `createdAt: Date`, `expiry: Date`.
  - `final class DriveShareStore` — `init(fileURL:)`, `static let default`, `all() -> [DriveShareRecord]` (newest first), `add(_:)` (replace by `folderID`), `remove(id:)`.
  - `enum DriveExpiry { static func expired(_ records: [DriveShareRecord], now: Date) -> [DriveShareRecord] }`.

- [ ] **Step 1: Write the failing test**

```swift
//  DriveShareStoreTests.swift
import XCTest
@testable import Muse

final class DriveShareStoreTests: XCTestCase {
    private func tempStore() -> (DriveShareStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("driveshares-\(UUID().uuidString).json")
        return (DriveShareStore(fileURL: url), url)
    }
    private func rec(_ id: String, folder: String, expiry: Date) -> DriveShareRecord {
        DriveShareRecord(id: id, collectionName: "C", folderID: folder, pageURL: "u",
                         itemCount: 1, createdAt: Date(timeIntervalSince1970: 0), expiry: expiry)
    }

    func testAddPersistsReplaceByFolderRemove() {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        store.add(rec("1", folder: "F", expiry: Date(timeIntervalSince1970: 10)))
        store.add(rec("2", folder: "F", expiry: Date(timeIntervalSince1970: 20))) // same folder → replace
        XCTAssertEqual(DriveShareStore(fileURL: url).all().map(\.id), ["2"])
        store.remove(id: "2")
        XCTAssertTrue(store.all().isEmpty)
    }

    func testExpiredSelectsOnlyPastRecords() {
        let now = Date(timeIntervalSince1970: 100)
        let past = rec("p", folder: "P", expiry: Date(timeIntervalSince1970: 50))
        let future = rec("f", folder: "F", expiry: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(DriveExpiry.expired([past, future], now: now).map(\.id), ["p"])
    }
}
```

- [ ] **Step 2: Run test, expect FAIL.**
- [ ] **Step 3: Implement**

```swift
//  DriveShareRecord.swift
//  Muse
//
//  Local record of a live Drive share (for the Manage list + the expiry
//  sweeper). JSON in App Support — never Drive, never SQLite.
//

import Foundation

struct DriveShareRecord: Codable, Identifiable, Equatable {
    let id: String
    let collectionName: String
    let folderID: String
    let pageURL: String
    let itemCount: Int
    let createdAt: Date
    let expiry: Date
}

enum DriveExpiry {
    static func expired(_ records: [DriveShareRecord], now: Date) -> [DriveShareRecord] {
        records.filter { $0.expiry < now }
    }
}

final class DriveShareStore {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.tarrats.Muse.driveShareStore")
    init(fileURL: URL) { self.fileURL = fileURL }

    static let `default`: DriveShareStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Muse", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return DriveShareStore(fileURL: base.appendingPathComponent("driveShares.json"))
    }()

    func all() -> [DriveShareRecord] { queue.sync { load().sorted { $0.createdAt > $1.createdAt } } }

    func add(_ r: DriveShareRecord) {
        queue.sync {
            var list = load().filter { $0.id != r.id && $0.folderID != r.folderID }
            list.append(r); save(list)
        }
    }
    func remove(id: String) { queue.sync { save(load().filter { $0.id != id }) } }

    private func load() -> [DriveShareRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder.iso.decode([DriveShareRecord].self, from: data) else { return [] }
        return list
    }
    private func save(_ list: [DriveShareRecord]) {
        guard let data = try? JSONEncoder.iso.encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder { static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }() }
private extension JSONDecoder { static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }() }
```

- [ ] **Step 4: Run test, expect PASS.**
- [ ] **Step 5: Commit** `feat: Drive share record store + pure expiry decision`.

---

## Phase 4 — Orchestration + expiry sweep

### Task 7: DriveShareService (publish orchestrator)

**Files:**
- Create: `Muse/Muse/Sharing/Drive/DriveShareService.swift`
- Modify: `Muse/Muse/Settings/AppSettings.swift` (store the Muse-root folder id + remembered form name/label)

**Interfaces:**
- Consumes: `GoogleOAuth`, `DriveClient`, `DriveShareManifest`, `DriveShareStore`, `CollectionPDFExporter`, `DriveConfig`.
- Produces:
  - `struct DriveShareForm` — `intro: String`, `label: String`, `name: String`, `date: Date`, `expiry: Date`.
  - `@MainActor final class DriveShareService: ObservableObject` — `@Published phase: Phase`, `func publish(form:title:urls:)`, `func cancel()`, `func reset()`.
  - `enum Phase: Equatable { case idle, signingIn, uploading(Int, Int), finalizing, done(String), failed(String) }`.

- [ ] **Step 1: Implement AppSettings additions**

In `Muse/Muse/Settings/AppSettings.swift`, add:

```swift
    // Google Drive share — remembered Muse-root folder id + last form text.
    static var driveRootFolderID: String? {
        get { UserDefaults.standard.string(forKey: "driveRootFolderID") }
        set { UserDefaults.standard.set(newValue, forKey: "driveRootFolderID") }
    }
    static var driveShareName: String {
        get { UserDefaults.standard.string(forKey: "driveShareName") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "driveShareName") }
    }
    static var driveShareLabel: String {
        get { UserDefaults.standard.string(forKey: "driveShareLabel") ?? String(localized: "Sent by") }
        set { UserDefaults.standard.set(newValue, forKey: "driveShareLabel") }
    }
```

- [ ] **Step 2: Implement DriveShareService**

```swift
//  DriveShareService.swift
//  Muse
//
//  Orchestrates a Drive publish: ensure sign-in → ensure Muse root → create the
//  share folder → upload images → make + upload the print PDF → set link-
//  sharing → assemble the page URL (manifest in the fragment) → record it.
//  Network happens ONLY here and in the sweeper, always behind a user action.
//

import Foundation

struct DriveShareForm {
    var intro: String
    var label: String
    var name: String
    var date: Date
    var expiry: Date
}

@MainActor final class DriveShareService: ObservableObject {
    enum Phase: Equatable {
        case idle, signingIn, uploading(Int, Int), finalizing, done(String), failed(String)
    }
    @Published private(set) var phase: Phase = .idle

    private let auth: GoogleOAuth
    private let client: DriveClient
    private let store: DriveShareStore
    private var task: Task<Void, Never>?

    init(auth: GoogleOAuth, store: DriveShareStore = .default) {
        self.auth = auth
        self.client = DriveClient(auth: auth)
        self.store = store
    }

    var isSignedIn: Bool { auth.isSignedIn }
    func reset() { cancel(); phase = .idle }
    func cancel() { task?.cancel(); task = nil }

    func publish(form: DriveShareForm, title: String, urls: [URL]) {
        guard urls.isEmpty == false else {
            phase = .failed(String(localized: "This collection has no images to share.")); return
        }
        task = Task { await run(form: form, title: title, urls: urls) }
    }

    private func run(form: DriveShareForm, title: String, urls: [URL]) async {
        do {
            if auth.isSignedIn == false {
                phase = .signingIn
                try await auth.signIn()
            }
            // Ensure the tidy top-level Muse folder.
            let root = try await client.ensureMuseRoot(existingID: AppSettings.driveRootFolderID)
            AppSettings.driveRootFolderID = root

            let iso = DateFormatter.driveDay
            let folderName = "\(title) — \(iso.string(from: form.date))"
            let folderID = try await client.createFolder(name: folderName, parent: root)

            var imageIDs: [String] = []
            for (i, url) in urls.enumerated() {
                if Task.isCancelled { try? await client.deleteFolder(id: folderID); return }
                phase = .uploading(i, urls.count)
                let mime = Self.mimeType(for: url)
                let id = try await client.uploadFile(url: url, name: url.lastPathComponent,
                                                     mime: mime, parent: folderID)
                imageIDs.append(id)
            }

            phase = .finalizing
            // Print-quality PDF from ORIGINALS (existing exporter), uploaded too.
            var pdfID: String?
            if let pdf = await CollectionPDFExporter.makePDF(
                urls: urls, title: title, count: urls.count, columns: 4,
                layoutAspect: nil, tileBackdrop: nil, tagLabels: [],
                pageSize: PaperSize.default.size) {
                pdfID = try? await client.uploadFile(url: pdf, name: "\(title).pdf",
                                                     mime: "application/pdf", parent: folderID)
            }

            try await client.setAnyoneReader(fileID: folderID)

            let manifest = DriveShareManifest(
                intro: form.intro, label: form.label, name: form.name,
                date: iso.string(from: form.date), expiry: iso.string(from: form.expiry),
                imageIDs: imageIDs, pdfID: pdfID)
            let pageURL = manifest.pageURL(base: DriveConfig.shareBaseURL)

            store.add(DriveShareRecord(id: UUID().uuidString, collectionName: title,
                                       folderID: folderID, pageURL: pageURL,
                                       itemCount: imageIDs.count, createdAt: Date(),
                                       expiry: form.expiry))
            // Remember the form text for next time.
            AppSettings.driveShareName = form.name
            AppSettings.driveShareLabel = form.label
            phase = .done(pageURL)
        } catch is CancellationError {
            phase = .idle
        } catch DriveAuthError.cancelled {
            phase = .idle
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case DriveAuthError.notSignedIn, DriveAuthError.refreshFailed:
            return String(localized: "Couldn't sign in to Google. Please try again.")
        case DriveClient.DriveError.http(let code) where code == 403:
            return String(localized: "Google Drive is full or the request was denied.")
        default:
            return String(localized: "Couldn't publish to Google Drive. Check your connection and try again.")
        }
    }

    private static func mimeType(for url: URL) -> String {
        if let t = UTType(filenameExtension: url.pathExtension), let m = t.preferredMIMEType { return m }
        return "application/octet-stream"
    }
}

import UniformTypeIdentifiers

extension DateFormatter {
    static let driveDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}
```

- [ ] **Step 3: Build, expect BUILD SUCCEEDED.**
- [ ] **Step 4: Commit** `feat: Drive publish orchestrator (sign-in → upload → PDF → link → URL)`.

---

### Task 8: Expiry sweeper

**Files:**
- Create: `Muse/Muse/Sharing/Drive/DriveExpirySweeper.swift`
- Modify: `Muse/Muse/MuseApp.swift` (run the sweep in the launch `.task`)

**Interfaces:**
- Consumes: `DriveShareStore`, `DriveExpiry`, `DriveClient`, `GoogleOAuth`.
- Produces: `@MainActor enum DriveExpirySweeper { static func sweep(auth: GoogleOAuth, store: DriveShareStore) async }`.

- [ ] **Step 1: Implement**

```swift
//  DriveExpirySweeper.swift
//  Muse
//
//  Muse-local expiry: on launch, hard-delete any Drive share folder past its
//  expiry (the folder Muse created — drive.file covers it), then drop the
//  record. No backend. Runs ONLY if there are expired records AND a token —
//  otherwise zero network.
//

import Foundation

@MainActor enum DriveExpirySweeper {
    static func sweep(auth: GoogleOAuth, store: DriveShareStore = .default) async {
        let due = DriveExpiry.expired(store.all(), now: Date())
        guard due.isEmpty == false, auth.isSignedIn else { return }
        let client = DriveClient(auth: auth)
        for record in due {
            do { try await client.deleteFolder(id: record.folderID); store.remove(id: record.id) }
            catch { /* leave the record; retry next launch */ }
        }
    }
}
```

- [ ] **Step 2: Wire into MuseApp launch task**

In `Muse/Muse/MuseApp.swift`, add a shared `GoogleOAuth` as a `@StateObject` and call the sweep in the existing `.task` on `ContentView`:

```swift
    @StateObject private var googleAuth = GoogleOAuth()
```
and inside the `.task { … }` after the housekeeping prune:
```swift
                    await DriveExpirySweeper.sweep(auth: googleAuth)
```
Pass `googleAuth` into the environment so the share UI reuses one instance:
```swift
                .environmentObject(appState)
                .environmentObject(googleAuth)
```

- [ ] **Step 3: Build, expect BUILD SUCCEEDED.**
- [ ] **Step 4: Commit** `feat: Muse-local Drive expiry sweep on launch`.

---

## Phase 5 — macOS UI

### Task 9: Publish form + progress + menu wiring

**Files:**
- Create: `Muse/Muse/Views/DriveShareForm.swift` (form + progress in one sheet, driven by `DriveShareService.Phase`)
- Modify: `Muse/Muse/Views/ShareCollectionButton.swift` (add "Share Drive Link", present the sheet)

**Interfaces:**
- Consumes: `DriveShareService`, `DriveShareForm`, `GoogleOAuth` (environment).
- Produces: `struct DriveShareSheet: View` (form → publish → link), presented from `ShareCollectionButton`.

- [ ] **Step 1: Implement `DriveShareSheet`** (form fields seeded from `AppSettings`; on Publish, swaps to a progress/result view bound to `service.phase`; `.done` shows the link with Copy + system share; `.failed` shows the message). Full SwiftUI in the file — fields: intro `TextField`, label `TextField`, name `TextField`, `DatePicker` date, `DatePicker` expiry; "Publish" calls `service.publish(...)`. Strings localized.

- [ ] **Step 2: Wire into ShareCollectionButton**

Add to its menu (the branch currently has only Save to…/Share):

```swift
            Divider()
            Button("Share Drive Link") { showingDriveShare = true }
```
state + sheet:
```swift
    @EnvironmentObject private var googleAuth: GoogleOAuth
    @StateObject private var driveService: DriveShareService
    @State private var showingDriveShare = false
```
(init `driveService` from the injected `googleAuth` in `.onAppear` or via a small wrapper; simplest: create it lazily in the sheet using the environment `googleAuth`.)
```swift
        .sheet(isPresented: $showingDriveShare, onDismiss: { driveService.reset() }) {
            DriveShareSheet(service: driveService, title: title, urls: exportURLs)
        }
```

- [ ] **Step 3: Build, expect BUILD SUCCEEDED.**
- [ ] **Step 4: Commit** `feat: Drive share form + publish sheet + menu entry`.

---

### Task 10: Manage Drive Shares (View menu)

**Files:**
- Create: `Muse/Muse/Views/ManageDriveSharesView.swift` (styled like `InfoSheet`, like the iCloud manage sheet)
- Modify: `Muse/Muse/Models/AppState.swift` (`@Published var driveSharesShown = false`)
- Modify: `Muse/Muse/ContentView.swift` (`.sheet(isPresented: $appState.driveSharesShown) { ManageDriveSharesView() }`)
- Modify: `Muse/Muse/MuseApp.swift` (View-menu `CommandGroup(after: .sidebar)` → "Manage Drive Shares…")

**Interfaces:**
- Consumes: `DriveShareStore`, `DriveClient`, `GoogleOAuth`.
- Produces: `struct ManageDriveSharesView: View` — list (name · count · expiry), Open Link, Delete now (unpublish = `DriveClient.deleteFolder` + `store.remove`).

- [ ] **Step 1: Implement** the view (24pt header + `SheetCloseButton`, 15/13pt rows, dividers between rows only; each row: name + "N images · expires <date>", an Open-link button, and a Delete-now button that deletes the Drive folder then refreshes). Delete uses the environment `GoogleAuth` → `DriveClient`.
- [ ] **Step 2: Add the AppState flag, ContentView sheet, and the View-menu command** (mirror the existing Find-Duplicates File-menu pattern but in `CommandGroup(after: .sidebar)`).
- [ ] **Step 3: Build, expect BUILD SUCCEEDED.**
- [ ] **Step 4: Commit** `feat: Manage Drive Shares… (View menu) + unpublish`.

---

## Phase 6 — Static web page

### Task 11: share.js pure logic + tests

**Files:**
- Create: `web/share/share.js`
- Create: `web/share/share.test.mjs`

**Interfaces:**
- Produces (exported for tests): `decodeManifest(fragment)`, `validateManifest(obj)`, `isExpired(manifest, now)`, `thumbURL(id)`, `pdfURL(id)`, `VALID_ID` regex.

- [ ] **Step 1: Write failing JS tests**

```js
// share.test.mjs  — run: node web/share/share.test.mjs
import assert from 'node:assert';
import { decodeManifest, validateManifest, isExpired, thumbURL, VALID_ID } from './share.js';

const sample = { i:'Intro', l:'Sent by', n:'The Project', d:'2026-04-01',
  e:'2026-04-04', g:['aaaaaaaaaaaaaaaaaaaa','bbbbbbbbbbbbbbbbbbbb'], p:'cccccccccccccccccccc' };
const b64url = Buffer.from(JSON.stringify(sample)).toString('base64')
  .replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');

assert.deepStrictEqual(decodeManifest(b64url), sample, 'round-trip decode');
assert.strictEqual(decodeManifest('!!!notbase64'), null, 'garbage → null');
assert.ok(validateManifest(sample), 'valid manifest');
assert.ok(!validateManifest({ ...sample, g:['short'] }), 'bad id rejected');
assert.ok(isExpired({ ...sample, e:'2020-01-01' }, new Date('2026-01-01')), 'past → expired');
assert.ok(!isExpired(sample, new Date('2026-04-02')), 'before expiry → live');
assert.ok(VALID_ID.test('aaaaaaaaaaaaaaaaaaaa'), 'id regex ok');
assert.ok(thumbURL('aaaaaaaaaaaaaaaaaaaa').startsWith('https://drive.google.com/thumbnail?id='), 'thumb url');
console.log('share.js: all tests passed');
```

- [ ] **Step 2: Run, expect FAIL** (`node web/share/share.test.mjs` → module not found / assertion).
- [ ] **Step 3: Implement share.js**

```js
// share.js — pure manifest logic (browser + node). The page imports the render
// glue; tests import only these pure functions.
export const VALID_ID = /^[A-Za-z0-9_-]{20,}$/;

export function decodeManifest(fragment) {
  if (!fragment) return null;
  try {
    let s = fragment.replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    const json = (typeof atob === 'function')
      ? decodeURIComponent(escape(atob(s)))
      : Buffer.from(s, 'base64').toString('utf8');
    return JSON.parse(json);
  } catch { return null; }
}

export function validateManifest(m) {
  if (!m || typeof m !== 'object') return false;
  if (!Array.isArray(m.g) || m.g.length === 0) return false;
  if (!m.g.every(id => VALID_ID.test(id))) return false;
  if (m.p != null && !VALID_ID.test(m.p)) return false;
  if (typeof m.e !== 'string' || isNaN(Date.parse(m.e))) return false;
  for (const k of ['i', 'l', 'n', 'd']) if (typeof m[k] !== 'string') return false;
  return true;
}

export function isExpired(m, now) { return new Date(m.e) < now; }
export function thumbURL(id) { return `https://drive.google.com/thumbnail?id=${id}&sz=w1600`; }
export function pdfURL(id) { return `https://drive.google.com/uc?export=download&id=${id}`; }

// Browser-only render glue (skipped under node).
if (typeof document !== 'undefined') {
  const m = decodeManifest(location.hash.slice(1));
  const root = document.getElementById('app');
  const set = (id, text) => { const el = document.getElementById(id); if (el) el.textContent = text; };
  if (!m || !validateManifest(m)) {
    root.dataset.state = 'unavailable';
  } else if (isExpired(m, new Date())) {
    root.dataset.state = 'expired';
    set('intro', m.i); set('label', m.l); set('name', m.n);
  } else {
    root.dataset.state = 'live';
    set('intro', m.i); set('label', m.l); set('name', m.n);
    set('expires', `Expires ${m.d ? new Date(m.e).toLocaleDateString() : m.e}`);
    const save = document.getElementById('save');
    if (m.p && save) { save.href = pdfURL(m.p); } else if (save) { save.style.display = 'none'; }
    const grid = document.getElementById('grid');
    for (const id of m.g) {
      const img = document.createElement('img');
      img.loading = 'lazy'; img.src = thumbURL(id); img.alt = '';
      grid.appendChild(img);
    }
  }
}
```

- [ ] **Step 4: Run JS tests, expect PASS.**
- [ ] **Step 5: Commit** `feat: share.js manifest decode/validate/expiry + tests`.

---

### Task 12: Page shell, styles, headers, deploy README

**Files:**
- Create: `web/share/index.html`, `web/share/share.css`, `web/share/_headers`, `web/share/README.md`

- [ ] **Step 1: index.html** — `<div id="app">` with `#intro`, `#label`, `#name`, `#expires`, `<a id="save">Save</a>`, `#grid`; `<script type="module" src="share.js">`. Empty text nodes (filled by JS via `textContent`). Three CSS-driven states via `[data-state]`.

- [ ] **Step 2: share.css** — matches the mockups: light-grey field (`#ececec`), top-left signature bar (intro bold; label grey + name black; `Expires` small grey; `Save` outlined pill), right-aligned "Sent by", responsive portrait grid (`grid-template-columns: repeat(auto-fill, minmax(150px, 1fr))`, ~3:4 tiles). `[data-state="expired"]`/`["unavailable"]` hide the grid + Save and show a centered message.

- [ ] **Step 3: _headers (Cloudflare)** — strict CSP + hardening:

```
/*
  Content-Security-Policy: default-src 'none'; img-src https://drive.google.com https://*.googleusercontent.com; script-src 'self'; style-src 'self'; base-uri 'none'; form-action 'none'
  X-Content-Type-Options: nosniff
  Referrer-Policy: no-referrer
  X-Frame-Options: DENY
```

- [ ] **Step 4: README.md** — how to deploy `web/share/` to Cloudflare Pages, set the custom domain, create the Google OAuth client (iOS/macOS type, scope `drive.file`), fill `DriveConfig.clientID` + the Info.plist reverse-client-id + `DriveConfig.shareBaseURL`, publish a privacy policy, and submit Google verification. Note the 100-user pre-verification cap.

- [ ] **Step 5: Commit** `feat: Drive share static page (shell, styles, CSP headers, deploy docs)`.

---

## Phase 7 — Localization, suite, docs

### Task 13: Localization

- [ ] **Step 1:** Run `xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj -localizationPath /tmp/muse-loc-drive -exportLanguage fr 2>&1 | tail -3`.
- [ ] **Step 2:** Fill `fr` for every new app string ("Share Drive Link", "Manage Drive Shares…", "Sent by", "Publish", "Expires", form labels, sign-in/progress/error copy, "Delete now", "Open Link", "Couldn't publish to Google Drive…", etc.). Verify 0 untranslated for the new keys.
- [ ] **Step 3: Commit** `i18n: French strings for Drive collection share`.

### Task 14: Full suite, docs, manual checklist

- [ ] **Step 1:** Run the full suite: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests 2>&1 | tail -8` → **TEST SUCCEEDED**. Run `node web/share/share.test.mjs` → all passed.
- [ ] **Step 2:** Update docs (accuracy, not padding): `CLAUDE.md` (status row "Polish 18 — Google Drive collection share"; a durable note that this is the **only sanctioned non-Sparkle network egress**, drive.file/PKCE/Keychain, Muse-local expiry, page-fragment manifest, owner prerequisites); `docs/architecture-map.md` (the `Sharing/Drive/` files + `web/share/`); a `docs/session-log.md` entry. Update the **Network policy** + **No network calls** rule in CLAUDE.md to record the single sanctioned exception.
- [ ] **Step 3:** Write the signed-build + provisioned-OAuth manual checklist into the session-log entry: sign in → publish a small collection → folder appears under `My Drive/Muse/<collection> — <date>/` with images + PDF, link-shared → open the page link (images render, Save downloads the PDF) → set a past expiry and relaunch Muse → folder deleted, page shows expired → Manage Drive Shares lists/opens/Delete-now works → sign out revokes.
- [ ] **Step 4: Commit** `docs: record Google Drive collection share (Polish 18)`.

---

## Self-Review (completed during planning)

- **Spec coverage:** OAuth PKCE + Keychain (T1–3) · drive.file REST + tidy Muse root (T4, T7) · URL-fragment manifest (T5) · expiry decision/store + Muse-local sweep (T6, T8) · publish form/progress + menu (T9) · View-menu manage + unpublish (T10) · static page render + XSS/CSP hardening (T11–12) · print-quality PDF from originals (T7) · Cloudflare deploy + owner prerequisites (T12) · localization (T13) · identity/network-policy doc change (T14). All spec sections map to a task.
- **Placeholder scan:** the only literal "REPLACE_…" values are the owner-provided OAuth client id / domain (by design, documented in T12 README) — not plan placeholders. Every code step has complete code; UI-view steps (T9/T10) specify exact fields/bindings/strings.
- **Type consistency:** `DriveShareManifest` CodingKeys (`i/l/n/d/e/g/p`) match `share.js` (`m.i/m.l/m.n/m.d/m.e/m.g/m.p`). `DriveShareService.Phase`, `DriveClient` method names, `DriveShareRecord` fields, `GoogleOAuth.validAccessToken()` are used identically across T7–T10.
- **Security:** scope pinned to `drive.file`; no secret in app; tokens Keychain-only device-only; manifest in URL fragment (never to host); page CSP `default-src 'none'`, `textContent` only, id regex; revoke on sign-out; network only behind explicit actions. Matches the spec's Security section.
