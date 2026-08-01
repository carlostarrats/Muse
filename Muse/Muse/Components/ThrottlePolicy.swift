//
//  ThrottlePolicy.swift
//  Muse
//
//  When background analysis is allowed to spawn work, as a pure truth table.
//
//  This is SCHEDULING, never an off switch (DECIDED #22 — analysis is always
//  on, no skip state). Pausing changes *when* files are picked up; markers,
//  selection logic and every data path are untouched, so a paused library is
//  simply a library whose backlog isn't moving yet.
//
//  Precedence matters: the user's own pause and thermal distress win outright,
//  battery/Low-Power only slows things down.
//

import Foundation

nonisolated enum ThrottlePolicy {
    enum Mode: Equatable, Sendable {
        case normal
        case reduced
        case paused
    }

    static func mode(thermal: ProcessInfo.ThermalState,
                     onBattery: Bool,
                     lowPower: Bool,
                     userPaused: Bool) -> Mode {
        if userPaused || thermal == .serious || thermal == .critical { return .paused }
        if onBattery || lowPower { return .reduced }
        return .normal
    }

    static func concurrency(_ mode: Mode) -> Int {
        scaled(mode, normal: AnalyzePipeline.analyzeConcurrency)
    }

    /// The same truth table for a pass whose full-speed width is its own. The
    /// backfills each picked a width tuned to what they do (4 header reads, 2
    /// Vision+CLIP scans); they must narrow under the same rules the analyze
    /// pass follows rather than be pinned to the analyze pass's width.
    static func scaled(_ mode: Mode, normal: Int) -> Int {
        switch mode {
        case .normal: return normal
        case .reduced: return 1
        case .paused: return 0
        }
    }
}
