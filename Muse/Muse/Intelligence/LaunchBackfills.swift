//
//  LaunchBackfills.swift
//  Muse
//
//  One chain for every launch-time backfill, and the single-flight gate the
//  passes share.
//
//  Specs 01–05 each added their own fire-and-forget `Task {}` to MuseApp's
//  `.task`, and none of them knew about the others: four passes started
//  together, contended for the ONE GRDB serial queue — the same queue the first
//  folder open needs — and two of them (geocode, deep analysis) could also be
//  reached a second time concurrently from an import or a model install.
//  Foundation §9 decided that shape: analysis is background, throttled and
//  pausable, and photos are browsable immediately with a budgeted cold start.
//  So they run in ONE serial chain now, cheapest first, at `.utility`, behind
//  the edit-index warm-up; each pass still gates itself on WorkThrottleStore.
//
//  Ordering rationale (cheap → expensive, and dependency-first):
//    1. IntentBackfill      — DB-only, no file I/O
//    2. PhotoHeaderBackfill — header reads; chains geocode + facets when it writes
//    3. GeocodeBackfill     — needs the coordinates #2 writes
//    4. DeepAnalysisBackfill — decode + Vision + CLIP; the heaviest, so last
//

import Foundation

/// Single-flight (with one trailing re-run) for passes that can be triggered
/// from more than one place.
///
/// A caller arriving while a pass is already running does NOT start a second
/// one over the same rows; instead the running pass repeats once when it
/// finishes, so a caller that just wrote rows is still guaranteed a pass that
/// begins after its writes. The second caller returns immediately rather than
/// blocking on someone else's pass.
actor BackfillCoordinator {
    static let shared = BackfillCoordinator()

    private var running: Set<String> = []
    private var pending: Set<String> = []

    func run(_ key: String, _ body: @Sendable () async -> Void) async {
        if running.contains(key) {
            pending.insert(key)
            return
        }
        running.insert(key)
        defer { running.remove(key) }
        repeat {
            pending.remove(key)
            await body()
        } while pending.contains(key)
    }
}

nonisolated enum LaunchBackfills {
    /// Runs every launch backfill, one at a time. Called once, from MuseApp.
    static func run() async {
        PhaseTrace.mark("intent-backfill.start")
        await IntentBackfill.run()
        PhaseTrace.mark("intent-backfill.end")

        // Header-only reads for GPS + EXIF, for libraries indexed before
        // v13/v14. Chains geocoding and the facet refresh when it writes.
        PhaseTrace.mark("photo-header-backfill.start")
        await PhotoHeaderBackfill.run()
        PhaseTrace.mark("photo-header-backfill.end")

        // Also run geocoding independently: coordinates may already exist (a
        // v13 library, or a GeoNamesDataset.version bump) with no fresh header
        // pass to chain from. Idempotent — selection is stale-by-marker — and
        // the chained copy above will already have drained it in the common
        // case, so this is normally one indexed query that finds nothing.
        PhaseTrace.mark("geocode-backfill.start")
        await GeocodeBackfill.run()
        PhaseTrace.mark("geocode-backfill.end")

        // Faces/pets/sharpness/stats (and CLIP vectors once the model is
        // installed) for files whose analyzed_hash is already current —
        // analyzePending would never revisit those.
        PhaseTrace.mark("deep-analysis-backfill.start")
        await DeepAnalysisBackfill.run()
        PhaseTrace.mark("deep-analysis-backfill.end")
    }
}
