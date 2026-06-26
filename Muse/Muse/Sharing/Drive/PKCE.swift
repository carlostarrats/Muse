//
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
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        // Never proceed with the all-zero buffer — that would yield a
        // predictable verifier/state. Trap rather than weaken the crypto.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status))")
        return Data(bytes)
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
