//
//  WorkProgress.swift
//  Muse
//
//  Combines every background phase into ONE progress reading.
//
//  The status pill used to be a four-way chain — Analyzing / Organizing /
//  Indexing / Loading images, first match wins — each with its own counter. That
//  was legible when phases lasted seconds, but after the 2026-07-28 performance
//  work analysis got ~100x faster and clustering ~96x faster, so the pill
//  switched labels faster than a human can read, and each switch restarted the
//  count at zero. Owner call: a user doesn't care which internal phase is
//  running, only that progress is happening — switching is just confusing.
//
//  So the pill shows one stable label and one bar that only ever moves forward.
//
//  Weighting: indexing and analysis are the two phases that actually take time
//  and both run over the same file set, so they split the bulk evenly.
//  Organizing and thumbnail streaming are the short tail.
//

import Foundation

struct WorkProgress: Equatable {
    /// A phase's share of the unified bar. Must sum to 1.
    static let indexShare = 0.45
    static let analyzeShare = 0.45
    static let organizeShare = 0.05
    static let thumbShare = 0.05

    /// Raw per-phase completion, each 0...1 (0 when the phase isn't running).
    struct Input: Equatable {
        var indexFraction: Double = 0
        var indexActive: Bool = false
        var analyzeFraction: Double = 0
        var analyzeActive: Bool = false
        var organizing: Bool = false
        var thumbFraction: Double = 0
        var thumbActive: Bool = false

        var anyActive: Bool { indexActive || analyzeActive || organizing || thumbActive }
    }

    /// Unclamped-by-history fraction implied by the current phase states.
    ///
    /// A phase that has FINISHED contributes its whole share, not zero —
    /// otherwise the bar would collapse the instant indexing handed off to
    /// analysis, which is precisely the "switches, then restarts at 0" the
    /// owner reported.
    static func rawFraction(_ i: Input) -> Double {
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        var total = 0.0
        // Indexing: in-flight → partial; done (analysis started, or anything
        // later is running) → full.
        if i.indexActive {
            total += indexShare * clamp(i.indexFraction)
        } else if i.analyzeActive || i.organizing {
            total += indexShare
        }
        if i.analyzeActive {
            total += analyzeShare * clamp(i.analyzeFraction)
        } else if i.organizing {
            total += analyzeShare
        }
        if i.organizing { total += organizeShare * 0.5 }
        if i.thumbActive { total += thumbShare * clamp(i.thumbFraction) }
        return clamp(total)
    }

    /// Monotonic state. `fraction` never decreases while work is ongoing.
    private(set) var fraction: Double = 0
    private(set) var isActive: Bool = false

    /// True once the work is done but the bar is still shown, filled, so the run
    /// visibly COMPLETES instead of vanishing partway.
    ///
    /// Without this the pill disappeared at whatever fraction the last active
    /// phase happened to reach — organizing contributes half its share and
    /// thumbnails may never run at all, so a finished run typically vanished
    /// somewhere in the 90s. Owner-reported as "a delay with a bit of a gap in
    /// the progression that visually looks weird". Reaching 100% and holding
    /// briefly reads as completion; stopping at 93% reads as a stall.
    private(set) var isFinishing: Bool = false

    mutating func update(_ i: Input) {
        guard i.anyActive else {
            // Everything idle. If we were mid-run, fill the bar and hold — the
            // view calls `reset()` after a beat. If we were already idle, stay
            // idle (this must not re-trigger the finish hold on every publish).
            if isActive && !isFinishing {
                fraction = 1
                isFinishing = true
            }
            return
        }
        // Work resumed while the completed bar was still held. That is a NEW
        // run, not a continuation, so end the old one first — otherwise the
        // monotonic `max` below would keep the bar pinned at the 1.0 the finish
        // hold set, and the new batch would show a permanently full bar.
        if isFinishing {
            isFinishing = false
            isActive = false
            fraction = 0
        }
        let raw = Self.rawFraction(i)
        // Only ever move forward within a run.
        fraction = isActive ? max(fraction, raw) : raw
        isActive = true
    }

    /// Clear after the finish hold, so the next run starts from zero.
    /// No-op if work restarted in the meantime.
    mutating func reset() {
        guard isFinishing else { return }
        fraction = 0
        isActive = false
        isFinishing = false
    }
}
