import Foundation
import GRDB

/// One-time pass: classify screenshots that were analyzed before intent typing
/// existed (intent_model_version IS NULL). Reads stored OCR + vision tags only —
/// never re-runs Vision. Safe to call on every launch; it self-limits.
enum IntentBackfill {
    static func run() async {
        guard let q = Database.shared.dbQueue else { return }
        let registry = IntelligenceRegistry.shared

        // Candidate screenshots: have a 'screenshot' vision-kind tag and no
        // intent_model_version yet.
        struct Candidate { let id: String; let ocr: String; let labels: [String] }
        let candidates: [Candidate] = (try? await q.read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT f.id FROM files f
                JOIN tags t ON t.file_id = f.id
                WHERE t.source = 'vision-kind' AND t.label = 'screenshot'
                  AND f.intent_model_version IS NULL
                """)
            return try ids.map { id in
                let ocr = (try String.fetchOne(db, sql:
                    "SELECT ocr_text FROM files_fts WHERE file_id = ?", arguments: [id])) ?? ""
                let labels = try String.fetchAll(db, sql:
                    "SELECT label FROM tags WHERE file_id = ? AND source = 'vision'",
                    arguments: [id])
                return Candidate(id: id, ocr: ocr, labels: labels)
            }
        }) ?? []
        guard !candidates.isEmpty else { return }

        let version = registry.intentModelVersion
        var didClassifyAny = false
        for c in candidates {
            let bucket = await registry.intentClassifier.classify(
                ocrText: IntentInput.ocrSnippet(c.ocr),
                visionLabels: c.labels)
            try? await q.write { db in
                try db.execute(sql:
                    "UPDATE files SET intent = ?, intent_model_version = ? WHERE id = ?",
                    arguments: [bucket?.rawValue, version, c.id])
            }
            if bucket != nil { didClassifyAny = true }
        }
        if didClassifyAny {
            await CollectionsEngine.shared.recluster()
        }
    }
}
