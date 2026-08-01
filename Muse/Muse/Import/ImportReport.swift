//
//  ImportReport.swift
//  Muse
//
//  The one report shape every import source accumulates into and the shared
//  report card renders. Models accumulate; the card computes nothing — that
//  split is what keeps "312 ratings, 1,840 keywords, 47 red labels →
//  `Label: Red`" identical no matter which source produced it.
//
//  Philosophy (foundation §7): never pretend a translation is lossless. The
//  `unsupportedSliders` disclosure and the stated-plainly `notices` are how a
//  source says what it could NOT bring across.
//

import Foundation

nonisolated struct ImportReport: Equatable, Identifiable {
    let id: UUID
    /// Localized display name of the source ("Lightroom", "Apple Photos", …).
    var sourceName: String
    /// Files copied/created (0 for in-place scans).
    var filesImported: Int = 0
    /// Files that received any metadata.
    var filesTouched: Int = 0
    var filesWithNone: Int = 0
    /// Unreadable / dataless / copy-failed.
    var filesSkipped: Int = 0
    var keywords: Int = 0
    var ratings: Int = 0
    var notes: Int = 0
    /// Supplement writes that filled lat/lon.
    var coordinates: Int = 0
    var captureDates: Int = 0
    var labelCounts: [LabelOutcome] = []
    /// Lightroom stacks written.
    var editsApproximated: Int = 0
    /// Had a Muse edit already — never clobbered.
    var editsSkippedExisting: Int = 0
    var presetsImported: Int = 0
    var unsupportedSliders: [String: Int] = [:]
    var collectionsCreated: Int = 0
    /// Source-specific stated-plainly lines.
    var notices: [String] = []

    init(id: UUID = UUID(), sourceName: String) {
        self.id = id
        self.sourceName = sourceName
    }
}

/// One raw source label value, how many files carried it, and what the user
/// chose to do with it (DECIDED #12 — the mapping is always reported back).
nonisolated struct LabelOutcome: Equatable {
    /// Raw source value ("Red", "Rouge", "Second") — never the mapped label.
    var label: String
    var count: Int
    var choice: LabelMapping.Choice
}
