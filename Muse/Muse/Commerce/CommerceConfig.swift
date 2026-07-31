//
//  CommerceConfig.swift
//  Muse
//
//  Product identifiers and endpoints. The only place these strings appear —
//  every StoreKit/announcements call site reads from here, never a literal.
//

import Foundation

enum CommerceConfig {
    /// One-time non-consumable unlock. MAS has no paid-upfront-with-trial, so
    /// the structure is forced: free download → trial → unlock IAP.
    static let unlockProductID = "com.tarrats.Muse.unlock"
    /// The sharing tier (custom domain + portfolio) is a digital SERVICE, so
    /// Apple requires it be an auto-renewable subscription.
    static let sharingYearlyProductID = "com.tarrats.Muse.sharing.yearly"
    static let sharingSubscriptionGroupID = "sharing"

    /// Same Cloudflare Pages host that serves the Drive share page — no new
    /// infrastructure, no new domain.
    static let announcementsURL = URL(string: "\(DriveConfig.shareBaseURL)/announcements.json")!

    /// Apple's promo-code redemption page. Gift codes are Apple promo codes
    /// (100 per IAP per app version), so there is no coupon system to build.
    static let redeemURL = URL(string: "https://apps.apple.com/redeem")!
}

/// What the user has paid for. Two independent axes: the app unlock and the
/// sharing subscription.
struct Entitlements: Equatable, Sendable {
    var unlocked: Bool = false
    var sharing: Bool = false
}
