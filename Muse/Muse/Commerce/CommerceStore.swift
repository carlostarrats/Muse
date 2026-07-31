//
//  CommerceStore.swift
//  Muse
//
//  Its own store object — AppState is frozen (DECIDED #26), so new features get
//  their own ObservableObject injected via .environmentObject, exactly like
//  GoogleOAuth.
//
//  Offline-tolerant by construction: the local cache is read SYNCHRONOUSLY in
//  init (so the first frame already knows whether the app is unlocked) and
//  StoreKit refreshes asynchronously afterwards. No identifiers are sent
//  anywhere, no receipt is posted to any server, no appAccountToken — StoreKit
//  traffic is OS-level, not one of the app's sanctioned network paths.
//

import Foundation
import StoreKit

@MainActor
final class CommerceStore: ObservableObject {
    @Published private(set) var entitlements: Entitlements
    @Published private(set) var trialPolicy: TrialPolicy

    private var cache: CommerceCache
    private var updatesTask: Task<Void, Never>?
    private let firstLaunchAnchor: Date

    private static let unlockedKey = "commerce.unlocked"
    private static let sharingKey = "commerce.sharing"
    private static let firstLaunchKey = "commerce.firstLaunch"

    init() {
        let loaded = Self.loadCache()
        self.cache = loaded
        self.entitlements = loaded.entitlements
        // enforced: false — see TrialGate's header. Nothing is blocked yet.
        self.trialPolicy = TrialPolicy()
        self.firstLaunchAnchor = Self.loadOrCreateFirstLaunchAnchor()

        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { [weak self] in await self?.refresh() }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - Reads

    func trialState(now: Date = Date()) -> TrialState {
        TrialGate.state(now: now, firstLaunch: firstLaunchAnchor,
                        entitled: entitlements.unlocked, policy: trialPolicy)
    }

    /// Empty until App Store Connect records exist — an owner step, not a code
    /// one. Must never throw or hang the caller when they don't.
    func products() async -> [Product] {
        (try? await Product.products(for: [
            CommerceConfig.unlockProductID,
            CommerceConfig.sharingYearlyProductID,
        ])) ?? []
    }

    // MARK: - Actions

    func purchase(_ productID: String) async {
        guard let product = await products().first(where: { $0.id == productID }) else { return }
        guard let result = try? await product.purchase() else { return }
        switch result {
        case .success(let verification):
            await handle(verification)
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }

    /// Walk the verified entitlements and reconcile. A COMPLETED walk that
    /// doesn't list an entitlement is the verified-absence signal that permits
    /// a revoke; a walk that never completes leaves the cache alone (that's the
    /// offline case, and it must not lock a paying user out).
    func refresh() async {
        var remote = Entitlements()
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            if transaction.productID == CommerceConfig.unlockProductID {
                remote.unlocked = true
            } else if transaction.productID == CommerceConfig.sharingYearlyProductID {
                remote.sharing = true
            }
        }
        let walkCompleted = !Task.isCancelled
        cache.merge(remoteGrants: remote)
        if walkCompleted {
            cache.revoke(unlocked: cache.unlocked && !remote.unlocked,
                         sharing: cache.sharing && !remote.sharing)
        }
        entitlements = cache.entitlements
        Self.saveCache(cache)
    }

    private func handle(_ verification: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = verification else { return }
        if transaction.productID == CommerceConfig.unlockProductID {
            cache.grant(unlocked: true)
        } else if transaction.productID == CommerceConfig.sharingYearlyProductID {
            cache.grant(sharing: true)
        }
        entitlements = cache.entitlements
        Self.saveCache(cache)
        await transaction.finish()
    }

    // MARK: - Persistence (UserDefaults mirror + Keychain unlock flag)

    private static func loadCache() -> CommerceCache {
        let defaults = UserDefaults.standard
        // OR of the two mirrors: a defaults wipe must not silently un-purchase
        // the app, and a Keychain that can't be read falls back to defaults.
        let unlocked = KeychainCommerceStore.readUnlockFlag() || defaults.bool(forKey: unlockedKey)
        return CommerceCache(unlocked: unlocked, sharing: defaults.bool(forKey: sharingKey))
    }

    private static func saveCache(_ cache: CommerceCache) {
        UserDefaults.standard.set(cache.unlocked, forKey: unlockedKey)
        UserDefaults.standard.set(cache.sharing, forKey: sharingKey)
        if cache.unlocked { KeychainCommerceStore.writeUnlockFlag(true) }
        else { KeychainCommerceStore.clearUnlockFlag() }
    }

    /// Earliest-wins: if the Keychain anchor and the UserDefaults mirror
    /// disagree, the earlier one is the truth. The anchor never moves forward —
    /// that would silently restart a trial.
    private static func loadOrCreateFirstLaunchAnchor() -> Date {
        let keychainDate = KeychainCommerceStore.readFirstLaunchAnchor()
        let defaultsDate = UserDefaults.standard.object(forKey: firstLaunchKey) as? Date
        let anchor = [keychainDate, defaultsDate].compactMap { $0 }.min() ?? Date()
        if keychainDate != anchor { KeychainCommerceStore.writeFirstLaunchAnchor(anchor) }
        if defaultsDate != anchor { UserDefaults.standard.set(anchor, forKey: firstLaunchKey) }
        return anchor
    }
}
