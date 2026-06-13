//
//  AspectRatioCache.swift
//  Muse
//
//  Supplies per-file aspect ratios (height ÷ width) so the grid can
//  precompute its masonry layout without rendering every tile.
//
//  Fast path: the Vision pipeline already stores pixel `width`/`height`
//  on `FileRow`, so an analyzed folder's ratios come from one bulk DB read.
//  Fallback: any image missing DB dimensions is resolved by a cheap ImageIO
//  header read (no full decode). Both run off the main thread; `version`
//  bumps whenever new ratios land so the grid recomputes geometry.
//

import SwiftUI
import GRDB
import ImageIO

@MainActor
final class AspectRatioCache: ObservableObject {

    /// Bumped whenever resolved ratios change, to trigger a geometry recompute.
    @Published private(set) var version = 0

    /// Standardized path → height ÷ width (only genuinely known ratios).
    private var ratios: [String: CGFloat] = [:]
    /// Paths already resolved (DB + ImageIO attempt), so we never refetch them.
    private var resolved: Set<String> = []
    /// Monotonic token so a stale background load can't clobber a newer one.
    private var loadToken = 0

    /// Aspect (height ÷ width) for a file. Returns a kind-appropriate default
    /// until the real ratio is resolved, so layout is stable from the first
    /// frame and only re-packs if a default turns out wrong.
    func aspect(for file: FileNode) -> CGFloat {
        let path = file.url.standardizedFileURL.path
        if let ratio = ratios[path] { return ratio }
        switch file.kind {
        case .image, .raw, .psd, .svg:
            return 1.0                 // square placeholder
        default:
            return 1.0 / 1.4           // labeled card (matches the old 1.4 w:h)
        }
    }

    /// Resolve dimensions for `files` in bulk (DB first, ImageIO for image
    /// gaps), off the main thread. Skips anything already resolved.
    func load(_ files: [FileNode]) {
        let needed = files.filter { !resolved.contains($0.url.standardizedFileURL.path) }
        guard !needed.isEmpty else { return }

        loadToken += 1
        let token = loadToken
        let paths = needed.map { $0.url.standardizedFileURL.path }
        let imageURLs: [URL] = needed.compactMap { file in
            switch file.kind {
            case .image, .raw, .psd: return file.url
            default: return nil
            }
        }

        Task.detached(priority: .utility) { [paths, imageURLs, token] in
            let fromDB = Self.dbDimensions(paths: paths)
            var fromIO: [String: CGFloat] = [:]
            for url in imageURLs {
                let path = url.standardizedFileURL.path
                if fromDB[path] != nil { continue }
                if let ratio = Self.imageIOAspect(url: url) { fromIO[path] = ratio }
            }
            await MainActor.run {
                guard token == self.loadToken else { return }
                for path in paths { self.resolved.insert(path) }
                var changed = false
                for (path, ratio) in fromDB where self.ratios[path] != ratio {
                    self.ratios[path] = ratio; changed = true
                }
                for (path, ratio) in fromIO where self.ratios[path] != ratio {
                    self.ratios[path] = ratio; changed = true
                }
                if changed { self.version &+= 1 }
            }
        }
    }

    // MARK: - Off-main resolvers

    /// Bulk lookup of stored pixel dimensions by absolute path, mirroring
    /// `SmartSorter.indexedRows` (paths → file_id → FileRow). Chunked to keep
    /// the SQL variable count well under SQLite's limit.
    private nonisolated static func dbDimensions(paths: [String]) -> [String: CGFloat] {
        guard let queue = Database.shared.dbQueue, !paths.isEmpty else { return [:] }
        return (try? queue.read { db -> [String: CGFloat] in
            var out: [String: CGFloat] = [:]
            var start = 0
            while start < paths.count {
                let chunk = Array(paths[start..<min(start + 800, paths.count)])
                start += 800
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let pathRows = try PathRow.fetchAll(
                    db,
                    sql: "SELECT * FROM paths WHERE absolute_path IN (\(placeholders)) AND is_alive = 1",
                    arguments: StatementArguments(chunk)
                )
                let fileIDs = pathRows.compactMap { $0.file_id }
                guard !fileIDs.isEmpty else { continue }
                let fileRows = try FileRow.filter(fileIDs.contains(FileRow.Columns.id)).fetchAll(db)
                let byID = Dictionary(uniqueKeysWithValues: fileRows.map { ($0.id, $0) })
                for path in pathRows {
                    if let id = path.file_id, let row = byID[id],
                       let w = row.width, let h = row.height, w > 0, h > 0 {
                        out[path.absolute_path] = CGFloat(h) / CGFloat(w)
                    }
                }
            }
            return out
        }) ?? [:]
    }

    /// Aspect from the image's metadata header only — no pixel decode.
    /// Honors EXIF orientation so rotated photos pack at their display aspect.
    private nonisolated static func imageIOAspect(url: URL) -> CGFloat? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0
        else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)   // 90°/270° → swap w & h
        return rotated ? CGFloat(w / h) : CGFloat(h / w)
    }
}
