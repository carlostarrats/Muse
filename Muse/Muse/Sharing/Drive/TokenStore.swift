//
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
