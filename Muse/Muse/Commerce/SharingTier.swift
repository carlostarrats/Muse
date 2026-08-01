//
//  SharingTier.swift
//  Muse
//
//  Portfolio (with Spec 08's custom domains) is the upsell tier. Enforcement
//  policy is Spec 09's decision, so this seam ships in the TrialGate posture:
//  it computes, it never blocks, until `enforced` flips true. Pure — no
//  StoreKit, no store reference; the caller passes the entitlement it already
//  has.
//

enum SharingTier {
    /// Spec 09 flips this. Until then every caller gets `true` and the portfolio
    /// UI is fully available (TestFlight validation needs it).
    static let enforced = false

    static func portfolioAvailable(entitledToSharing: Bool) -> Bool {
        enforced ? entitledToSharing : true
    }
}
