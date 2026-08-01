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
    static let maxPerLaunch = 5_000
    static let concurrency = 2
    static let writeChunk = 200
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

    private struct ScanResult: Sendable {
        var traits: PhotoTraitsRow?
        var clip: ClipEmbeddingRow?
    }

    static func run() async {
        guard let queue = Database.shared.dbQueue else { return }
        let clipReady = await MainActor.run { ClipModelStore.shared.isReady }

        let candidateIDs: [String] = (try? await queue.read { db -> [String] in
            var ids = try staleTraitsFileIDs(db: db, limit: maxPerLaunch)
            if clipReady {
                let clipIDs = try staleClipFileIDs(db: db, limit: maxPerLaunch)
                // A file needing only ONE of the two still gets scanned once —
                // the shared decode covers both.
                var seen = Set(ids)
                for id in clipIDs where seen.insert(id).inserted { ids.append(id) }
            }
            return Array(ids.prefix(maxPerLaunch))
        }) ?? []
        guard !candidateIDs.isEmpty else { return }

        let context: [String: (url: URL, hash: String)] = (try? await queue.read { db in
            var map: [String: (url: URL, hash: String)] = [:]
            for id in candidateIDs {
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT f.content_hash AS h, MIN(p.absolute_path) AS p
                    FROM files f JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
                    WHERE f.id = ?
                    """, arguments: [id]),
                    let hash: String = row["h"], let path: String = row["p"] else { continue }
                map[id] = (URL(fileURLWithPath: path), hash)
            }
            return map
        }) ?? [:]

        var pending: [ScanResult] = []

        await withTaskGroup(of: ScanResult?.self) { group in
            var iterator = candidateIDs.makeIterator()

            func spawnNext() {
                while let id = iterator.next() {
                    guard let ctx = context[id] else { continue }
                    group.addTask(priority: .utility) {
                        await scanOne(fileID: id, url: ctx.url, hash: ctx.hash, clipReady: clipReady)
                    }
                    return
                }
            }
            for _ in 0..<concurrency { spawnNext() }

            for await result in group {
                if let result { pending.append(result) }
                if pending.count >= writeChunk {
                    await flush(&pending, queue: queue)
                }
                spawnNext()
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
