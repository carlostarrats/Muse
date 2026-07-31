//
//  CommerceCache.swift
//  Muse
//
//  Permissive-only local mirror of entitlements: it can GRANT ahead of a
//  verified StoreKit read (offline tolerance — a purchased user on a plane is
//  never locked out while StoreKit warms up) and never revokes on its own.
//  Revocation follows only an explicit verified-absence signal from a
//  completed StoreKit walk.
//
//  Pure and mutable, with no I/O of its own — CommerceStore wraps it around
//  the actual persistence, matching this codebase's separation of pure logic
//  from I/O (Sidecar.merge, AnnouncementFeed.parse, StarRating.resolution).
//

import Foundation
import Security

struct CommerceCache: Equatable, Sendable {
    private(set) var unlocked: Bool
    private(set) var sharing: Bool

    init(unlocked: Bool, sharing: Bool) {
        self.unlocked = unlocked
        self.sharing = sharing
    }

    /// Grant is one-way — passing `false` never clears anything. Use `revoke`.
    mutating func grant(unlocked: Bool? = nil, sharing: Bool? = nil) {
        if unlocked == true { self.unlocked = true }
        if sharing == true { self.sharing = true }
    }

    /// Permissive-only: only ever ADDS entitlements the remote snapshot grants;
    /// never removes one the snapshot happens not to list.
    mutating func merge(remoteGrants: Entitlements) {
        if remoteGrants.unlocked { unlocked = true }
        if remoteGrants.sharing { sharing = true }
    }

    /// The only way an entitlement is cleared — called only after a verified
    /// StoreKit read confirms its absence (refund, subscription lapse).
    mutating func revoke(unlocked: Bool = false, sharing: Bool = false) {
        if unlocked { self.unlocked = false }
        if sharing { self.sharing = false }
    }

    var entitlements: Entitlements { Entitlements(unlocked: unlocked, sharing: sharing) }
}

/// Keychain mirror for the two values that must survive a defaults wipe: the
/// unlock flag and the first-launch anchor (a trial anchor stored only in
/// UserDefaults resets itself). Same access class as the Drive token store —
/// device-only, never synced.
enum KeychainCommerceStore {
    private static let service = "com.tarrats.Muse.commerce"
    private static let unlockAccount = "unlock-flag"
    private static let anchorAccount = "first-launch"

    // MARK: - Generic

    private static func read(_ account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func write(_ data: Data, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func delete(_ account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(base as CFDictionary)
    }

    // MARK: - Values

    static func readUnlockFlag() -> Bool {
        read(unlockAccount).map { $0 == Data([1]) } ?? false
    }

    static func writeUnlockFlag(_ value: Bool) {
        write(Data([value ? 1 : 0]), account: unlockAccount)
    }

    static func clearUnlockFlag() { delete(unlockAccount) }

    static func readFirstLaunchAnchor() -> Date? {
        guard let data = read(anchorAccount),
              let seconds = try? JSONDecoder().decode(Double.self, from: data) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func writeFirstLaunchAnchor(_ date: Date) {
        guard let data = try? JSONEncoder().encode(date.timeIntervalSince1970) else { return }
        write(data, account: anchorAccount)
    }
}
