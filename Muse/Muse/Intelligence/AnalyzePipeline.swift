//
//  AnalyzePipeline.swift
//  Muse
//
//  Orchestrates "Analyze this file/folder" — runs Vision pipeline,
//  writes results to the DB, populates FTS5. Per Q10, only ever
//  triggered explicitly by the user; never automatic.
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
    }

    // MARK: - Per-file

    private func analyzeOne(fileID: String, url: URL) async {
        // Skip non-image kinds; Vision pipeline only handles images
        let kind = AssetKind.detect(at: url)
        guard kind == .image || kind == .raw || kind == .psd else { return }

        let result = await VisionServices.analyze(url: url)

        guard let queue = Database.shared.dbQueue else { return }
        let caption = result.caption()
        let basename = url.lastPathComponent
        let now = Int64(Date().timeIntervalSince1970)
        let hasFP = result.didSucceedFeaturePrint

        do {
            try await queue.write { db in
                // Update files row
                if var file = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db) {
                    file.width = result.width
                    file.height = result.height
                    file.caption = caption
                    file.dominant_color = result.dominantColor
                    if hasFP {
                        file.feature_print = result.featurePrint
                    }
                    file.last_seen_at = now
                    try file.update(db)
                }

                // Insert vision tags (manual-beats-vision per Q32 — ignore on conflict if a
                // manual tag already exists for this label).
                for (label, conf) in result.classifications {
                    if let existing = try TagRow
                        .filter(TagRow.Columns.file_id == fileID)
                        .filter(TagRow.Columns.label == label)
                        .fetchOne(db) {
                        if existing.source == "vision" {
                            // Update confidence
                            var t = existing
                            t.confidence = Double(conf)
                            try t.update(db)
                        }
                        // Manual tag: leave alone
                    } else {
                        var t = TagRow(
                            id: UUID().uuidString,
                            file_id: fileID,
                            label: label,
                            source: "vision",
                            confidence: Double(conf)
                        )
                        try t.insert(db)
                    }
                }

                // FTS5 — keyed by files.id (immutable). Replace the row.
                try db.execute(sql: "DELETE FROM files_fts WHERE file_id = ?", arguments: [fileID])
                try db.execute(sql: """
                    INSERT INTO files_fts(file_id, basename, ocr_text, caption)
                    VALUES (?, ?, ?, ?)
                """, arguments: [fileID, basename, result.ocrText, caption])
            }
        } catch {
            print("[AnalyzePipeline] write failed: \(error)")
        }
    }
}
