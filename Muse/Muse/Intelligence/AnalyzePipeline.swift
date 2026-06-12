//
//  AnalyzePipeline.swift
//  Muse
//
//  Orchestrates "Analyze this file/folder" — runs Vision pipeline,
//  writes results to the DB, populates FTS5. Runs automatically after
//  indexing for files whose analyzed_hash is stale (supersedes Q10's
//  manual-only rule); the ✨ button forces a full re-run. Manual tags
//  always beat vision tags (Q32), so re-analysis never undoes the user.
//

import Foundation
import GRDB

@MainActor
final class AnalyzePipeline: ObservableObject {
    static let shared = AnalyzePipeline()

    @Published var isRunning: Bool = false
    @Published var progress: Double = 0
    @Published var current: String = ""

    private init() {}

    // MARK: - File-level

    func analyze(file url: URL) async {
        guard let queue = Database.shared.dbQueue else { return }
        // Find the file row by alive path
        let absPath = url.standardizedFileURL.path
        let fileID: String? = (try? await queue.read { db -> String? in
            try PathRow
                .filter(PathRow.Columns.absolute_path == absPath)
                .filter(PathRow.Columns.is_alive == 1)
                .fetchOne(db)?.file_id
        }) ?? nil
        guard let id = fileID else { return }
        isRunning = true
        current = url.lastPathComponent
        defer { isRunning = false; current = ""; progress = 0 }
        await analyzeOne(fileID: id, url: url)
        isRunning = false; current = ""; progress = 0
        await CollectionsEngine.shared.recluster()
    }

    /// The automatic pass: of `urls`, analyze only those whose stored
    /// analyzed_hash is missing or stale (new or edited images). Runs
    /// after every index pass — analyzing twice is a provable no-op.
    func analyzePending(in urls: [URL]) async {
        guard let queue = Database.shared.dbQueue else { return }
        // A pass may already be running (e.g. the previous folder's) —
        // wait our turn instead of silently skipping this folder.
        while isRunning {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let paths = urls.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }
        let pending: Set<String> = (try? await queue.read { db in
            let marks = databaseQuestionMarks(count: paths.count)
            return try Set(String.fetchAll(db, sql: """
                SELECT p.absolute_path FROM paths p
                JOIN files f ON f.id = p.file_id
                WHERE p.is_alive = 1
                  AND p.absolute_path IN (\(marks))
                  AND (f.analyzed_hash IS NULL
                       OR f.analyzed_hash != f.content_hash)
                """, arguments: StatementArguments(paths)))
        }) ?? []
        guard !pending.isEmpty else { return }
        let pendingURLs = urls.filter { pending.contains($0.standardizedFileURL.path) }
        await analyze(folder: pendingURLs)
    }

    func analyze(folder urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard let queue = Database.shared.dbQueue else { return }
        isRunning = true
        progress = 0
        defer { isRunning = false; current = ""; progress = 0 }

        for (idx, url) in urls.enumerated() {
            current = url.lastPathComponent
            let absPath = url.standardizedFileURL.path
            let fileID: String? = (try? await queue.read { db -> String? in
                try PathRow
                    .filter(PathRow.Columns.absolute_path == absPath)
                    .filter(PathRow.Columns.is_alive == 1)
                    .fetchOne(db)?.file_id
            }) ?? nil
            if let id = fileID {
                await analyzeOne(fileID: id, url: url)
            }
            progress = Double(idx + 1) / Double(urls.count)
        }
        isRunning = false; current = ""; progress = 0
        await CollectionsEngine.shared.recluster()
    }

    // MARK: - Per-file

    private func analyzeOne(fileID: String, url: URL) async {
        // Skip non-image kinds; Vision pipeline only handles images
        let kind = AssetKind.detect(at: url)
        guard kind == .image || kind == .raw || kind == .psd else { return }

        let registry = IntelligenceRegistry.shared
        guard let out = await registry.tagger.analyze(url: url) else { return }

        guard let queue = Database.shared.dbQueue else { return }
        let caption = out.caption
        let basename = url.lastPathComponent
        let now = Int64(Date().timeIntervalSince1970)
        let paletteJSON: String? = out.palette.isEmpty ? nil :
            String(data: try! JSONEncoder().encode(out.palette), encoding: .utf8)
        let taggerVersion = registry.tagger.modelVersion

        do {
            try await queue.write { db in
                // Update files row
                if var file = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db) {
                    file.width = out.width
                    file.height = out.height
                    file.caption = caption
                    file.dominant_color = out.dominantColor
                    file.palette = paletteJSON
                    if let fp = out.featurePrint {
                        file.feature_print = fp
                    }
                    file.last_seen_at = now
                    // Mark analyzed-at-this-content so the automatic pass
                    // skips it until the file's bytes actually change.
                    file.analyzed_hash = file.content_hash
                    try file.update(db)
                }

                // Insert vision tags (manual-beats-vision per Q32 — ignore on conflict if a
                // manual tag already exists for this label).
                for tag in out.tags {
                    if let existing = try TagRow
                        .filter(TagRow.Columns.file_id == fileID)
                        .filter(TagRow.Columns.label == tag.label)
                        .fetchOne(db) {
                        if existing.source != "manual" {
                            // Update confidence + provenance
                            var t = existing
                            t.confidence = tag.confidence
                            t.source = tag.source
                            t.model_version = taggerVersion
                            try t.update(db)
                        }
                        // Manual tag: leave alone
                    } else {
                        var t = TagRow(
                            id: UUID().uuidString,
                            file_id: fileID,
                            label: tag.label,
                            source: tag.source,
                            confidence: tag.confidence,
                            model_version: taggerVersion
                        )
                        try t.insert(db)
                    }
                }

                // FTS5 — keyed by files.id (immutable). Replace the row.
                try db.execute(sql: "DELETE FROM files_fts WHERE file_id = ?", arguments: [fileID])
                try db.execute(sql: """
                    INSERT INTO files_fts(file_id, basename, ocr_text, caption)
                    VALUES (?, ?, ?, ?)
                """, arguments: [fileID, basename, out.ocrText, caption])
            }
        } catch {
            print("[AnalyzePipeline] write failed: \(error)")
        }

        // Embedding write — separate from the main transaction; embedder may be nil.
        if let embedder = registry.embedder {
            let doc = (out.tags.map(\.label) + [out.caption ?? "", String(out.ocrText.prefix(300))])
                .joined(separator: " ")
            if let vec = embedder.embed(doc) {
                try? await queue.write { db in
                    var row = EmbeddingRow(file_id: fileID,
                                           vector: VectorMath.toData(vec),
                                           model_version: embedder.modelVersion,
                                           updated_at: Int64(Date().timeIntervalSince1970))
                    try row.save(db)
                }
            }
        }
    }
}
