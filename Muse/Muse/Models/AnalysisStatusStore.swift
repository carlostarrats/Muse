//
//  AnalysisStatusStore.swift
//  Muse
//
//  "34,000 of 100,000 analyzed" — the findable progress number (DECIDED #23),
//  and the measured per-file cost the import-size FYI extrapolates from.
//
//  Pattern B, zero AppState integration. Deliberately SEPARATE from the status
//  pill: the pill reports whether background work is happening right now, this
//  reports how much of the library has been through it. Nothing here touches
//  `WorkProgress`.
//
//  `secondsPerFile` is an EMA and is NOT `@Published` — it changes on every
//  completed file, and republishing that would re-render the Settings sheet a
//  few times a second for a number nobody watches tick.
//

import Foundation
import GRDB

@MainActor
final class AnalysisStatusStore: ObservableObject {
    static let shared = AnalysisStatusStore()

    /// Alive image/raw/psd files — the ones the analyze pass can act on.
    @Published private(set) var analyzableTotal = 0
    /// Of those, the ones whose `analyzed_hash` is missing or stale.
    @Published private(set) var pending = 0

    /// Exponential moving average of per-file analyze duration. α = 0.1.
    private(set) var secondsPerFile: Double?
    private(set) var completions = 0

    static let emaAlpha = 0.1
    /// At most one count query per this interval; overlapping triggers coalesce.
    static let refreshInterval: TimeInterval = 5

    private var lastRefresh: Date?
    private var refreshToken = 0
    /// Backlog at launch, so a FYI fires on newly ADDED work rather than on a
    /// stable pre-existing queue the user has already lived with.
    private var baselinePending: Int?
    private var fyiShownThisLaunch = false

    /// One-way reference OUT, installed once at launch — the same shape
    /// `EditStore` uses. The FYI is raised through the existing
    /// `alertRequest` seam, so this store still adds no `@Published` property
    /// to AppState and forwards nothing back to it.
    private weak var host: AppState?

    init() {}

    func installHost(_ appState: AppState) { host = appState }

    var analyzed: Int { max(analyzableTotal - pending, 0) }

    var estimateSeconds: TimeInterval? {
        AnalysisEstimator.estimate(pending: pending, secondsPerFile: secondsPerFile,
                                   completions: completions)
    }

    func recordCompletion(duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        completions += 1
        if let current = secondsPerFile {
            secondsPerFile = Self.emaAlpha * duration + (1 - Self.emaAlpha) * current
        } else {
            secondsPerFile = duration
        }
    }

    /// One off-main count query, rate-limited and token-guarded. Called from
    /// index batches, analyze-pass completions and backfill chunks — all of
    /// which fire far more often than the number can meaningfully change.
    func refresh(force: Bool = false) {
        if !force, let last = lastRefresh,
           Date().timeIntervalSince(last) < Self.refreshInterval { return }
        lastRefresh = Date()
        refreshToken += 1
        let token = refreshToken
        guard let queue = Database.shared.dbQueue else { return }
        Task { [weak self] in
            let counts: (Int, Int)? = try? await queue.read { db -> (Int, Int) in
                let total = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM files f
                    WHERE f.kind IN ('image', 'raw', 'psd')
                      AND EXISTS (SELECT 1 FROM paths p WHERE p.file_id = f.id AND p.is_alive = 1)
                    """) ?? 0
                let pending = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM files f
                    WHERE f.kind IN ('image', 'raw', 'psd')
                      AND (f.analyzed_hash IS NULL OR f.analyzed_hash != f.content_hash)
                      AND EXISTS (SELECT 1 FROM paths p WHERE p.file_id = f.id AND p.is_alive = 1)
                    """) ?? 0
                return (total, pending)
            }
            guard let self, let counts, token == self.refreshToken else { return }
            self.analyzableTotal = counts.0
            self.pending = counts.1
            self.considerFYI()
        }
    }

    /// The import-size heads-up: at most once per launch, only when the backlog
    /// GREW by a calibration's worth since launch and the measured estimate
    /// exceeds the threshold. Below that: silent, always.
    private func considerFYI() {
        if baselinePending == nil { baselinePending = pending }
        guard !fyiShownThisLaunch,
              let baseline = baselinePending,
              pending - baseline >= AnalysisEstimator.calibrationMinimum,
              let estimate = estimateSeconds,
              AnalysisEstimator.shouldOffer(estimate: estimate) else { return }
        fyiShownThisLaunch = true
        let duration = AnalysisEstimator.approximateDuration(estimate)
        let count = pending
        host?.alertRequest = MuseAlert(
            title: String(localized: "Analyzing your photos"),
            message: String(localized: "Heads up: analyzing \(count) photos will take about \(duration). They're ready to browse now — search and colors get smarter as it finishes."),
            confirmTitle: String(localized: "OK"),
            cancelTitle: nil)
    }
}
