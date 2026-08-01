import Foundation
import GRDB

/// One-time pass: classify screenshots that were analyzed before intent typing
/// existed (intent_model_version IS NULL). Reads stored OCR + vision tags only —
/// never re-runs Vision. Safe to call on every launch; it self-limits.
enum IntentBackfill {
    /// Cap per launch, like the other backfills — an uncapped pass on a large
    /// screenshot-heavy library holds every candidate's OCR text in RAM at
    /// once and runs its whole classification burst in one launch.
    static let maxPerLaunch = 5_000
    /// Rows per write transaction. This was one transaction PER FILE, i.e. a
    /// full fsync round trip on the serial queue per screenshot, ahead of
    /// whatever the UI wanted from that same queue.
    static let writeChunk = 200

    static func run() async {
        await BackfillCoordinator.shared.run("intent") { await work() }
    }

    private static func work() async {
        guard let q = Database.shared.dbQueue else { return }
        let registry = IntelligenceRegistry.shared

        // Candidate screenshots: have a 'screenshot' vision-kind tag and no
        // intent_model_version yet. Ids only — the OCR text is fetched a chunk
        // at a time below, so a screenshot-heavy library never holds every
        // candidate's full OCR in RAM at once.
        let candidateIDs: [String] = (try? await q.read { db in
            try String.fetchAll(db, sql: """
                SELECT f.id FROM files f
                JOIN tags t ON t.file_id = f.id
                WHERE t.source = 'vision-kind' AND t.label = 'screenshot'
                  AND f.intent_model_version IS NULL
                LIMIT \(maxPerLaunch)
                """)
        }) ?? []
        guard !candidateIDs.isEmpty else { return }

        struct Candidate { let id: String; let ocr: String; let labels: [String] }
        let version = registry.intentModelVersion
        var didClassifyAny = false

        for slice in stride(from: 0, to: candidateIDs.count, by: writeChunk) {
            if Task.isCancelled { break }
            // Additive scheduling only, same as the other passes: the pause
            // gate stops new classification, in-flight work finishes.
            await WorkThrottleStore.shared.waitUntilRunnable()
            let ids = Array(candidateIDs[slice..<min(slice + writeChunk, candidateIDs.count)])

            // Two queries per chunk rather than two per file — the queue is a
            // single serial connection and everything the UI wants queues
            // behind a long read.
            let chunk: [Candidate] = (try? await q.read { db in
                let marks = databaseQuestionMarks(count: ids.count)
                var ocr: [String: String] = [:]
                for row in try Row.fetchAll(
                    db, sql: "SELECT file_id, ocr_text FROM files_fts WHERE file_id IN (\(marks))",
                    arguments: StatementArguments(ids)) {
                    guard let id: String = row["file_id"] else { continue }
                    ocr[id] = row["ocr_text"] ?? ""
                }
                var labels: [String: [String]] = [:]
                for row in try Row.fetchAll(
                    db, sql: """
                        SELECT file_id, label FROM tags
                        WHERE source = 'vision' AND file_id IN (\(marks))
                        """,
                    arguments: StatementArguments(ids)) {
                    guard let id: String = row["file_id"], let label: String = row["label"]
                    else { continue }
                    labels[id, default: []].append(label)
                }
                return ids.map { Candidate(id: $0, ocr: ocr[$0] ?? "",
                                           labels: labels[$0] ?? []) }
            }) ?? []

            var batch: [(id: String, bucket: String?)] = []
            for c in chunk {
                let bucket = await registry.intentClassifier.classify(
                    ocrText: IntentInput.ocrSnippet(c.ocr),
                    visionLabels: c.labels)
                batch.append((id: c.id, bucket: bucket?.rawValue))
                if bucket != nil { didClassifyAny = true }
            }
            // One transaction per chunk. This was one transaction — one fsync
            // round trip — PER FILE.
            let rows = batch
            try? await q.write { db in
                for row in rows {
                    try db.execute(sql:
                        "UPDATE files SET intent = ?, intent_model_version = ? WHERE id = ?",
                        arguments: [row.bucket, version, row.id])
                }
            }
        }

        if didClassifyAny {
            await CollectionsEngine.shared.recluster()
        }
    }
}
