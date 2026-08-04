//
//  DeepAnalysisBackfill.swift
//  Muse
//
//  Launch pass that fills photo_traits (and, when the CLIP model is
//  installed, clip_embeddings) for files whose `analyzed_hash` is already
//  current, so `analyzePending` will never revisit them. Modelled on
//  PhotoHeaderBackfill: fire-and-forget Task from MuseApp's `.task`,
//  PhaseTrace-marked, self-limiting.
//
//  A file that can't be decoded still gets its marker row stamped (NULL trait
//  fields / NULL vector) — never leave a permanent-retry gap.
//

import CoreGraphics
import Foundation
import GRDB

nonisolated enum DeepAnalysisBackfill {
    /// Files SCANNED per launch. See `scanList` — absent rows don't spend it.
    nonisolated static let maxPerLaunch = 5_000
    /// Rows the selection queries may return, so `maxPerLaunch` real files are
    /// still reachable behind a wall of rows whose file is gone. Bounded (and
    /// id-only) rather than unlimited: the context query that follows costs one
    /// indexed read per `contextChunk`, and that must not scale with a library
    /// whose ghost count is unbounded.
    static let selectionCeiling = 50_000
    static let concurrency = 2
    static let writeChunk = 200
    /// Candidates per context query. Comfortably under SQLite's bound-variable
    /// ceiling, and short enough that the serial queue is handed back often.
    static let contextChunk = 500
    /// The traits pass needs far less resolution than the 4096px Vision pass:
    /// face rectangles, animal detection and a normalized sharpness score are
    /// all stable well below that, and CLIP's own input is 256px.
    static let decodeMaxPixel = 1024

    /// Image-kind files with an alive path whose photo_traits marker is
    /// missing, stale-by-hash, or version-behind. Pure/testable — no decode,
    /// no Vision call.
    static func staleTraitsFileIDs(db: GRDB.Database, limit: Int) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT f.id FROM files f
            JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
            LEFT JOIN photo_traits t ON t.file_id = f.id
            WHERE f.kind IN ('image', 'raw', 'psd')
              AND (t.file_id IS NULL
                   OR t.traits_scanned_hash != f.content_hash
                   OR t.traits_version < ?)
            GROUP BY f.id
            LIMIT ?
            """, arguments: [PhotoTraits.currentVersion, limit])
    }

    /// Image-kind files whose clip_embeddings marker is missing, stale-by-hash
    /// or from a different model generation. A NULL vector at the CURRENT
    /// generation is an attempted-marker and is deliberately NOT reselected.
    static func staleClipFileIDs(db: GRDB.Database, limit: Int) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT f.id FROM files f
            JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
            LEFT JOIN clip_embeddings c ON c.file_id = f.id
            WHERE f.kind IN ('image', 'raw', 'psd')
              AND (c.file_id IS NULL
                   OR c.embedded_hash != f.content_hash
                   OR c.model_generation != ?)
            GROUP BY f.id
            LIMIT ?
            """, arguments: [ClipModel.current.generation, limit])
    }

    /// The candidates actually worth opening, up to `limit` of them.
    ///
    /// `paths.is_alive = 1` is a CLAIM, and nothing in the app is allowed to
    /// re-check it outside a current root: `PathReconciler.reconcileByExistence`
    /// walks a root's subtree, and a sandboxed app has no access to a folder
    /// whose bookmark is gone. So a folder that was indexed, removed from the
    /// sidebar and deleted from disk keeps alive rows indefinitely (until
    /// `Housekeeping` retires them at 180 days).
    ///
    /// Selecting them was a permanent retry loop: the decode fails, `scanOne`
    /// deliberately does NOT stamp a marker for an absent file, and the same
    /// rows come back next launch. Owner-reported as the app "analyzing every
    /// time you make a new build" — 2,923 rows from four deleted test folders.
    ///
    /// They are DROPPED rather than stamped, so nothing is recorded and a file
    /// that comes back is still scanned. Fail-safe by construction: a
    /// transiently unreachable root just skips this launch.
    ///
    /// `limit` is a SCAN budget, not a candidate budget — an absent row costs a
    /// `stat` and spends nothing. It used to be spent by the SQL `LIMIT`, so a
    /// library with more ghosts than the cap would never reach a single real
    /// photo, and nothing would say so because the pass "completed". Hence the
    /// wider `selectionCeiling` on the queries feeding this.
    ///
    /// `exists` mirrors `reconcileByExistence`'s probe — dataless iCloud files
    /// still have a filesystem entry, and the old-style evicted placeholder is
    /// offline, not deleted.
    static func scanList(candidateIDs: [String],
                         context: [String: (url: URL, hash: String)],
                         limit: Int,
                         exists: (String) -> Bool = {
                             FileManager.default.fileExists(atPath: $0)
                             || PathReconciler.isEvictedPlaceholder($0)
                         }) -> [String] {
        var kept: [String] = []
        kept.reserveCapacity(min(limit, candidateIDs.count))
        for id in candidateIDs {
            guard kept.count < limit else { break }
            guard let ctx = context[id], exists(ctx.url.path) else { continue }
            kept.append(id)
        }
        return kept
    }

    private struct ScanResult: Sendable {
        var traits: PhotoTraitsRow?
        var clip: ClipEmbeddingRow?
    }

    /// Single-flight: this is reachable from the launch chain AND from
    /// `ClipModelStore` after a model install, and the two select overlapping
    /// rows. The flush guard is content-hash based, so a concurrent second run
    /// wouldn't corrupt anything — it would just decode and Vision every file
    /// twice.
    static func run() async {
        await BackfillCoordinator.shared.run("deep-analysis") { await work() }
    }

    private static func work() async {
        guard let queue = Database.shared.dbQueue else { return }
        let clipReady = await MainActor.run { ClipModelStore.shared.isReady }

        let candidateIDs: [String] = (try? await queue.read { db -> [String] in
            var ids = try staleTraitsFileIDs(db: db, limit: selectionCeiling)
            if clipReady {
                let clipIDs = try staleClipFileIDs(db: db, limit: selectionCeiling)
                // A file needing only ONE of the two still gets scanned once —
                // the shared decode covers both.
                var seen = Set(ids)
                for id in clipIDs where seen.insert(id).inserted { ids.append(id) }
            }
            return Array(ids.prefix(selectionCeiling))
        }) ?? []
        guard !candidateIDs.isEmpty else { return }

        // One query per 500 candidates, not one per candidate: a DatabaseQueue
        // is a single serial connection, so 5,000 statements inside one read
        // hold the queue — and every interactive fetch behind it — for the
        // whole enumeration.
        let context: [String: (url: URL, hash: String)] = (try? await queue.read { db in
            var map: [String: (url: URL, hash: String)] = [:]
            for slice in stride(from: 0, to: candidateIDs.count, by: contextChunk) {
                let ids = Array(candidateIDs[slice..<min(slice + contextChunk, candidateIDs.count)])
                let marks = databaseQuestionMarks(count: ids.count)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT f.id AS id, f.content_hash AS h, MIN(p.absolute_path) AS p
                    FROM files f JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
                    WHERE f.id IN (\(marks))
                    GROUP BY f.id
                    """, arguments: StatementArguments(ids))
                for row in rows {
                    guard let id: String = row["id"], let hash: String = row["h"],
                          let path: String = row["p"] else { continue }
                    map[id] = (URL(fileURLWithPath: path), hash)
                }
            }
            return map
        }) ?? [:]

        // Off the serial queue and before any decode: rows can outlive the file
        // they name, and re-attempting those every launch is a loop that cannot
        // converge. This is also where the per-launch budget is applied, so an
        // absent row costs a `stat` and nothing else. See `scanList`.
        let scanIDs = scanList(candidateIDs: candidateIDs, context: context,
                               limit: maxPerLaunch)
        guard !scanIDs.isEmpty else { return }

        var pending: [ScanResult] = []

        await withTaskGroup(of: ScanResult?.self) { group in
            var iterator = scanIDs.makeIterator()
            var inFlight = 0

            /// Throttle and cancellation are consulted per SPAWN, not per
            /// 200-row write chunk: gating on the chunk meant Pause (or a
            /// thermal event) took another ~200 decode+Vision+CLIP scans to
            /// take effect. Files already in flight still finish normally —
            /// same rule as AnalyzePipeline, so a pause stays resumable.
            func spawnNext() async -> Bool {
                if Task.isCancelled { return false }
                await WorkThrottleStore.shared.waitUntilRunnable()
                while let id = iterator.next() {
                    guard let ctx = context[id] else { continue }
                    group.addTask(priority: .utility) {
                        await scanOne(fileID: id, url: ctx.url, hash: ctx.hash, clipReady: clipReady)
                    }
                    return true
                }
                return false
            }

            /// Re-read per spawn so a machine that goes to battery mid-pass
            /// narrows without a restart.
            func width() async -> Int {
                max(1, await WorkThrottleStore.shared.concurrency(normal: concurrency))
            }

            var target = await width()
            while inFlight < target {
                guard await spawnNext() else { break }
                inFlight += 1
            }

            for await result in group {
                inFlight -= 1
                if let result { pending.append(result) }
                if pending.count >= writeChunk {
                    await flush(&pending, queue: queue)
                }
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                target = await width()
                while inFlight < target {
                    guard await spawnNext() else { break }
                    inFlight += 1
                }
            }
        }
        if !pending.isEmpty {
            await flush(&pending, queue: queue)
        }
    }

    private static func scanOne(fileID: String, url: URL, hash: String,
                                clipReady: Bool) async -> ScanResult? {
        guard let raster = VisionServices.boundedDecode(url: url, maxPixel: decodeMaxPixel) else {
            // Undecodable: stamp attempted-markers with NULL payloads so this
            // file isn't retried every launch. A file that isn't there at all
            // (or a dataless iCloud placeholder whose bytes haven't landed) is
            // deliberately NOT stamped — same rule as the indexer.
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return ScanResult(
                traits: PhotoTraitsRow(file_id: fileID, traits_scanned_hash: hash,
                                       traits_version: PhotoTraits.currentVersion,
                                       face_count: nil, largest_face_frac: nil,
                                       face_quality: nil, pet_count: nil, sharpness: nil,
                                       clip_high_r: nil, clip_high_g: nil, clip_high_b: nil,
                                       clip_low: nil, noise_sigma: nil),
                clip: clipReady
                    ? ClipEmbeddingRow(file_id: fileID, embedded_hash: hash,
                                       model_generation: ClipModel.current.generation, vector: nil)
                    : nil)
        }

        let result = await VisionServices.analyze(cgImage: raster)
        var clipRow: ClipEmbeddingRow?
        if clipReady {
            let vector = await ClipEngine.shared.embedImage(raster)
            clipRow = ClipEmbeddingRow(file_id: fileID, embedded_hash: hash,
                                       model_generation: ClipModel.current.generation,
                                       vector: vector.map { ClipVectors.toData($0) })
        }
        return ScanResult(
            traits: PhotoTraitsRow(file_id: fileID, traits_scanned_hash: hash,
                                   traits_version: PhotoTraits.currentVersion,
                                   face_count: result.faceCount,
                                   largest_face_frac: result.largestFaceFrac,
                                   face_quality: result.faceQuality,
                                   pet_count: result.petCount,
                                   sharpness: result.sharpness,
                                   clip_high_r: result.clipHighR,
                                   clip_high_g: result.clipHighG,
                                   clip_high_b: result.clipHighB,
                                   clip_low: result.clipLow,
                                   noise_sigma: result.noiseSigma),
            clip: clipRow)
    }

    private static func flush(_ rows: inout [ScanResult], queue: DatabaseQueue) async {
        let batch = rows
        rows.removeAll(keepingCapacity: true)
        try? await queue.write { db in
            for result in batch {
                // Only commit if the file's content_hash still matches what we
                // scanned — a mid-pass edit leaves the row stale rather than
                // stamping new-hash-wrong-values.
                let scannedHash = result.traits?.traits_scanned_hash ?? result.clip?.embedded_hash
                guard let scannedHash,
                      let fileID = result.traits?.file_id ?? result.clip?.file_id,
                      try String.fetchOne(db, sql: "SELECT content_hash FROM files WHERE id = ?",
                                          arguments: [fileID]) == scannedHash
                else { continue }
                if var traits = result.traits { try traits.save(db) }
                if var clip = result.clip { try clip.save(db) }
            }
        }
    }
}
