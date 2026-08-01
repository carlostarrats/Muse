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
        switch mode {
        case .normal: return AnalyzePipeline.analyzeConcurrency
        case .reduced: return 1
        case .paused: return 0
        }
    }
}
