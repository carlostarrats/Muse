//
//  TrialGate.swift
//  Muse
//
//  MAS forbids paid-upfront-with-trial, so the structure is forced: free
//  download → trial → unlock IAP. The policy itself is OPEN (pricing is Spec
//  09's call), so this ships with `enforced: false`: the state is computed and
//  displayable, but nothing is ever blocked by it. Flipping one Bool is what
//  turns it on, once pricing is decided.
//
//  Pure — no clock, no storage. `now` and `firstLaunch` are parameters so every
//  edge (missing anchor, clock rollback, day boundaries) is unit-testable.
//

import Foundation

struct TrialPolicy: Equatable, Sendable {
    var duration: TimeInterval = 14 * 86_400
    /// Ships false — see file header. An unenforced policy never reports
    /// `.expired`.
    var enforced: Bool = false
}

enum TrialState: Equatable, Sendable {
    case unlocked
    case trial(daysLeft: Int)
    case expired
}

enum TrialGate {
    static func state(now: Date, firstLaunch: Date?, entitled: Bool,
                      policy: TrialPolicy) -> TrialState {
        if entitled { return .unlocked }
        // No anchor recorded yet = the very first run; treat as day 0 rather
        // than as an infinitely old install.
        let anchor = firstLaunch ?? now
        // max(0,…) clamps a backwards clock: setting the date back must not
        // read as negative elapsed time and hand out extra days.
        let elapsed = max(0, now.timeIntervalSince(anchor))
        let remaining = policy.duration - elapsed
        if remaining <= 0 {
            return policy.enforced ? .expired : .trial(daysLeft: 0)
        }
        return .trial(daysLeft: Int(remaining / 86_400))
    }
}
