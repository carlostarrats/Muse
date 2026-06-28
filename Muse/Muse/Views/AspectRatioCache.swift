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

    /// Authoritative aspect from a tile's freshly-decoded thumbnail (exact
    /// image dimensions). This is the backstop that guarantees a VISIBLE tile's
    /// frame matches its image — no grey letterbox — even if the pre-pass below
    /// hasn't reached it yet. Bumps are coalesced so a burst of tiles reporting
    /// at once triggers a single recompute.
    func report(aspect: CGFloat, forStandardizedPath path: String) {
        guard aspect > 0, ratios[path] != aspect else { return }
        ratios[path] = aspect
        resolved.insert(path)
        if !pendingBump {
            pendingBump = true
            Task { @MainActor in self.pendingBump = false; self.version &+= 1 }
        }
    }
    private var pendingBump = false

    /// Drop cached ratios for paths no longer on screen, bounding the cache to
    /// roughly one folder's worth across a long session (the same reason
    /// `tileFrames` is cleared on folder switch). Re-resolving on revisit is a
    /// cheap bulk DB read, so this trades a tiny re-read for bounded memory.
    /// No-ops on an empty set so a transient mid-load empty `visibleFiles` doesn't
    /// wipe the cache.
    func prune(toVisible files: [FileNode]) {
        guard !files.isEmpty else { return }
        let keep = Set(files.map { $0.url.standardizedFileURL.path })
        ratios = ratios.filter { keep.contains($0.key) }
        resolved = resolved.filter { keep.contains($0) }
    }

    /// Resolve dimensions for `files` off the main thread. DB-known dimensions
    /// publish IMMEDIATELY; the ImageIO header reads for the rest run
    /// CONCURRENTLY and publish in small batches. The old version did a single
    /// sequential ImageIO pass that published only at the very end, so a folder
    /// with many un-analyzed images left every tile on the square default
    /// (= images letterboxed in grey) until the whole pass finished.
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
        // Read the DB handle here on the main actor and hand it to the
        // background task, rather than reaching for the @MainActor singleton
        // from nonisolated code (mirrors Housekeeping.pruneUnreachable(queue:)).
        let queue = Database.shared.dbQueue

        Task.detached(priority: .utility) { [paths, imageURLs, token, queue] in
            // 1) DB dimensions for the whole set — fast, published right away.
            //    Everything NOT awaiting an ImageIO read (DB hits + non-image
            //    files like PDFs that have no aspect to resolve) is marked
            //    resolved now, so a later load() skips them instead of
            //    reprocessing the whole folder each call.
            let fromDB = queue.map { Self.dbDimensions(paths: paths, queue: $0) } ?? [:]
            let gaps = imageURLs.filter { fromDB[$0.standardizedFileURL.path] == nil }
            let gapSet = Set(gaps.map { $0.standardizedFileURL.path })
            let nonGap = paths.filter { !gapSet.contains($0) }
            await self.apply(fromDB, resolvedPaths: nonGap, token: token)

            // 2) ImageIO header reads for everything the DB didn't cover, run
            //    concurrently and flushed in batches so the layout converges in
            //    a fraction of a second.
            await withTaskGroup(of: (String, CGFloat?).self) { group in
                for url in gaps {
                    group.addTask { (url.standardizedFileURL.path, Self.imageIOAspect(url: url)) }
                }
                var batch: [String: CGFloat] = [:]
                var attempted: [String] = []
                for await (path, ratio) in group {
                    attempted.append(path)
                    if let ratio { batch[path] = ratio }
                    if attempted.count >= 40 {
                        await self.apply(batch, resolvedPaths: attempted, token: token)
                        batch.removeAll(keepingCapacity: true)
                        attempted.removeAll(keepingCapacity: true)
                    }
                }
                if !attempted.isEmpty {
                    await self.apply(batch, resolvedPaths: attempted, token: token)
                }
            }
        }
    }

    /// Merge one batch of resolved ratios and bump `version` once if anything
    /// changed. `resolvedPaths` are marked done even when their ratio was nil,
    /// so a failed read isn't retried (the thumbnail `report` can still fix it).
    private func apply(_ batch: [String: CGFloat], resolvedPaths: [String], token: Int) {
        guard token == loadToken else { return }
        for path in resolvedPaths { resolved.insert(path) }
        var changed = false
        for (path, ratio) in batch where ratios[path] != ratio {
            ratios[path] = ratio; changed = true
        }
        if changed { version &+= 1 }
    }

    // MARK: - Off-main resolvers

    /// Bulk lookup of stored pixel dimensions by absolute path, mirroring
    /// `SmartSorter.indexedRows` (paths → file_id → FileRow). Chunked to keep
    /// the SQL variable count well under SQLite's limit.
    private nonisolated static func dbDimensions(paths: [String],
                                                 queue: DatabaseQueue) -> [String: CGFloat] {
        guard !paths.isEmpty else { return [:] }
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
