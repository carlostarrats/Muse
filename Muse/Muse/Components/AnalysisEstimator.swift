//
//  AnalysisEstimator.swift
//  Muse
//
//  How long the remaining analysis backlog will take, and whether that is
//  worth telling the user about (DECIDED #23).
//
//  The estimate is MEASURED on this Mac — an M1 Air and an M4 Pro differ 3–4×,
//  so a hardcoded per-photo cost would embarrass itself on one of them. Nothing
//  is offered until `calibrationMinimum` files have actually completed.
//
//  The FYI is gated on TIME, not count: 8,000 photos might warrant a heads-up on
//  one machine and be a non-event on another. Below the threshold it is fully
//  silent — one button, never a choice, never a skip path.
//

import Foundation

nonisolated enum AnalysisEstimator {
    /// Completions required before any estimate exists.
    static let calibrationMinimum = 200
    /// ~25 minutes.
    static let fyiThresholdSeconds: TimeInterval = 25 * 60

    static func estimate(pending: Int, secondsPerFile: Double?, completions: Int) -> TimeInterval? {
        guard completions >= calibrationMinimum, let secondsPerFile,
              secondsPerFile.isFinite, secondsPerFile > 0, pending > 0 else { return nil }
        return Double(pending) * secondsPerFile
    }

    static func shouldOffer(estimate: TimeInterval?) -> Bool {
        guard let estimate else { return false }
        return estimate > fyiThresholdSeconds
    }

    /// "about 2 hours" — deliberately approximate; a precise figure invites
    /// disappointment when the machine warms up and slows down.
    static func approximateDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour] : [.minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        return formatter.string(from: seconds) ?? ""
    }
}
