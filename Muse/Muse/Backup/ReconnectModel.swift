//
//  ReconnectModel.swift
//  Muse
//
//  Drives the Reconnect wizard. The user locates each backed-up folder ONE AT A
//  TIME (folders can live anywhere on the new Mac); locating a folder reconnects
//  it immediately — index + hash through the real Indexer, match the archive's
//  occurrences by content hash, apply metadata, then refresh collections + stars.
//  There is deliberately no "do it all" master action (it would assume every
//  folder shares one parent). Heavy lifting delegates to the pure
//  matcher/materializer/applier.
//

import Foundation
import SwiftUI
import GRDB

@MainActor
final class ReconnectModel: ObservableObject {
    enum FolderStatus: Equatable {
        case pending, working, clean
        /// Reconnected, but not entirely confidently: some occurrences had no
        /// match at all (`unmatched`), and/or were matched only by filename
        /// (`nameOnly`, a different-content file with the same name — surfaced
        /// for the user to eyeball rather than trusted like an exact hash).
        case flagged(unmatched: Int, nameOnly: Int)
        /// A database write threw while applying — the folder is NOT safely
        /// reconnected even though files may have matched.
        case failed
    }
    struct FolderRow: Identifiable {
        let id: String              // original root_path
        let displayName: String
        var newLocation: URL?
        var status: FolderStatus
    }
    struct CollectionStatusRow: Identifiable {
        let id: String
        let name: String
        var reconnected: Int
        var total: Int
    }

    @Published var folders: [FolderRow]
    @Published var collectionStatuses: [CollectionStatusRow]

    /// Library-global edit assets are restored ONCE, not per folder. They are
    /// `INSERT OR IGNORE` so repeating them is harmless correctness-wise, but a
    /// LUT blob is up to 25 MB and SQLite still binds it into the statement
    /// before the id conflict is detected — a ten-folder restore would push
    /// hundreds of megabytes through the writer for nothing.
    private var didApplyEditAssets = false

    private let archive: BackupArchive
    private let hashToFile: [String: BackupFile]
    private let hashForOriginalPath: [String: String]

    var collectionsDone: Int { collectionStatuses.filter { $0.reconnected > 0 }.count }

    var overallPercent: Int {
        let total = collectionStatuses.reduce(0) { $0 + $1.total }
        guard total > 0 else { return 0 }
        let done = collectionStatuses.reduce(0) { $0 + $1.reconnected }
        return Int((Double(done) / Double(total) * 100).rounded())
    }

    init(archive: BackupArchive) {
        self.archive = archive
        var byHash: [String: BackupFile] = [:]
        var hashForPath: [String: String] = [:]
        for f in archive.files {
            byHash[f.content_hash] = f
            for o in f.occurrences { hashForPath[o.original_path] = f.content_hash }
        }
        self.hashToFile = byHash
        self.hashForOriginalPath = hashForPath
        self.folders = archive.roots.map {
            FolderRow(id: $0.path, displayName: $0.display_name, newLocation: nil, status: .pending)
        }
        self.collectionStatuses = archive.collections
            .filter { $0.is_hidden == 0 }
            .map { CollectionStatusRow(id: $0.id, name: $0.name,
                                       reconnected: 0, total: $0.members.count) }
    }

    /// Locate one backed-up folder at `location` and reconnect it immediately.
    /// Independent per folder — others can be reconnected before or after, in
    /// any order, from anywhere on disk.
    func reconnectFolder(id: String, location: URL, bookmarks: BookmarkStore) async {
        guard let queue = Database.shared.dbQueue,
              let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[idx].newLocation = location
        folders[idx].status = .working

        // Add the located folder as a sidebar root — but not twice. Relocating the
        // same folder, or a backup whose folders overlap an existing root, would
        // otherwise append a duplicate Root (and a second security scope).
        let alreadyRoot = bookmarks.roots.contains {
            bookmarks.url(for: $0)?.standardizedFileURL.path == location.standardizedFileURL.path
        }
        if !alreadyRoot { _ = bookmarks.addRoot(at: location) }

        // Enumerate the folder's indexable files off the main actor.
        let (pairs, imageURLs) = await Task.detached(priority: .utility) {
            () -> (pairs: [(URL, AssetKind)], images: [URL]) in
            var pairs: [(URL, AssetKind)] = []
            var images: [URL] = []
            let fm = FileManager.default
            // Match the app's indexing policy (FolderReader): hidden files
            // excluded, packages opaque — default options would index hidden
            // media and files INSIDE bundles (.app/.photoslibrary), creating
            // alive rows the grid never shows but search/FTS still surfaces.
            guard let en = fm.enumerator(at: location,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { return ([], []) }
            // `nextObject()` rather than for-in: DirectoryEnumerator's
            // Sequence conformance is unavailable from an async context.
            //
            // The non-URL case CONTINUES rather than ending the loop. Writing
            // this as `while let url = en.nextObject() as? URL` reads fine and
            // is wrong: a single non-URL element would terminate the walk and
            // silently index only part of the folder — during a RESTORE, where
            // a short enumeration means unmatched occurrences the user is then
            // asked to eyeball.
            while let next = en.nextObject() {
                guard let url = next as? URL else { continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                let kind = AssetKind.detect(at: url)
                guard kind != .folder, kind.hasNativeViewer || kind == .archive else { continue }
                pairs.append((url, kind))
                if kind == .image || kind == .raw || kind == .psd { images.append(url) }
            }
            return (pairs, images)
        }.value

        // Index through the real pipeline — creates the FileRow (by content hash)
        // + PathRow that applyMeta/collections join against.
        _ = await Indexer.shared.indexBatch(pairs, priority: .high)

        // Match the archive's occurrences for this folder against the now-indexed
        // disk files (their real content hashes).
        let disk = await diskFiles(under: location, queue: queue)
        let occurrences = archive.files.flatMap { $0.occurrences }.filter { $0.root_path == id }
        // `uniquingKeysWith` (not `uniqueKeysWithValues:`, which traps on a
        // duplicate key): a legit archive has unique original_paths, but a
        // corrupt/hand-edited .muselibrary can repeat one — fail gracefully
        // (keep the first) rather than crash the whole Restore.
        let expected = Dictionary(
            occurrences.compactMap { o -> (String, String)? in
                guard let h = hashForOriginalPath[o.original_path] else { return nil }
                return (o.original_path, h)
            }, uniquingKeysWith: { first, _ in first })
        let match = ReconnectMatcher.match(occurrences: occurrences, disk: disk, expectedHash: expected)
        let nameOnlyCount = match.matches.filter { $0.kind == .nameOnly }.count

        var byFile: [String: [OccurrenceMatch]] = [:]
        for m in match.matches {
            guard let h = hashForOriginalPath[m.occurrence.original_path] else { continue }
            byFile[h, default: []].append(m)
        }
        var applyFailed = false
        // Paths whose occurrence carried edit data, collected so the render
        // seams can be refreshed once at the end rather than per file.
        var restoredEditPaths: [String] = []
        for (hash, matches) in byFile {
            guard let file = hashToFile[hash] else { continue }
            do { try await ReconnectApplier.applyMeta(matches: matches, file: file, queue: queue) }
            catch { applyFailed = true }
            for m in matches where m.occurrence.edit_stack != nil
                || !(m.occurrence.edit_versions ?? []).isEmpty {
                restoredEditPaths.append(m.diskPath)
            }
        }

        // Rebuild collections + stars from the current DB and refresh the readout
        // (collections light up incrementally as each folder comes back), then
        // reload the live engine so the sidebar/Collections page actually show
        // them — the early addRoot→reload fired before these writes landed.
        if let map = try? await ReconnectApplier.currentFileIDForHash(queue: queue) {
            // Where each archived occurrence actually landed. Collection
            // membership is restored through this rather than through the hash,
            // which cannot tell two byte-identical copies apart.
            var diskPathForOriginal: [String: String] = [:]
            for matches in byFile.values {
                for m in matches { diskPathForOriginal[m.occurrence.original_path] = m.diskPath }
            }
            do {
                try await ReconnectApplier.applyCollections(
                    archive, fileIDForHash: map,
                    diskPathForOriginal: diskPathForOriginal, queue: queue)
            } catch { applyFailed = true }
            try? await ReconnectApplier.applyStars(archive, queue: queue)
            await CollectionsEngine.shared.reload()
            for j in collectionStatuses.indices {
                let coll = archive.collections.first { $0.id == collectionStatuses[j].id }
                collectionStatuses[j].reconnected = coll?.members
                    .filter { map[$0.content_hash] != nil }.count ?? 0
            }
        } else {
            applyFailed = true
        }

        // Edit assets and the edit-save consequences sit OUTSIDE the
        // hash-map branch above, deliberately. Neither needs that map — the
        // assets are library-global and the consequences key off paths — and
        // `applyMeta` has already written the edit rows unconditionally. Nested
        // inside it, a failed `currentFileIDForHash` left the edits in the
        // database with nothing on screen knowing: `EditStackIndex` is
        // path-keyed and was built at launch, and the thumbnail cache still
        // holds each file's UNEDITED render under a key the new stack no longer
        // matches. That is the same defect class as the folder-rename one.
        //
        // `applyHydratedConsequences` is exactly the right list (index warm,
        // version counts, `markContentChanged`, generation bump) and
        // deliberately omits the sidecar re-export — also correct here:
        // hydration owns sidecar reconciliation, and a restore must not stomp a
        // newer on-disk sidecar with archive state.
        //
        // LUTs are invalidated FIRST: `EditRenderer.canRender` consults
        // `LutRegistry` while the index is being warmed, so a stale miss cached
        // before this point would mark a restored LUT-bearing stack
        // unrenderable and show the original.
        var restoredLutIDs: [String] = []
        if !didApplyEditAssets,
           let ids = try? await ReconnectApplier.applyEditAssets(archive, queue: queue) {
            restoredLutIDs = ids
            // Latched only on SUCCESS, so a transient write failure on the
            // first folder retries with the next one instead of silently
            // costing the user every preset and LUT in the archive.
            didApplyEditAssets = true
        }
        if !restoredEditPaths.isEmpty || !restoredLutIDs.isEmpty {
            for id in restoredLutIDs { LutRegistry.invalidate(id) }
            await EditStore.shared.applyHydratedConsequences(
                for: restoredEditPaths.map { URL(fileURLWithPath: $0) })
        }

        // Status: a DB write failure means the folder is NOT safely reconnected,
        // even if files matched. Otherwise clean only when every occurrence was an
        // exact-hash match; name-only or unmatched occurrences flag it for a look.
        if applyFailed {
            folders[idx].status = .failed
        } else if match.unmatched.isEmpty && nameOnlyCount == 0 {
            folders[idx].status = .clean
        } else {
            folders[idx].status = .flagged(unmatched: match.unmatched.count, nameOnly: nameOnlyCount)
        }

        // Reconcile: analyze anything new/changed the backup didn't cover. Matched
        // files were marked analyzed by applyMeta, so they're skipped here.
        if !imageURLs.isEmpty {
            await AnalyzePipeline.shared.analyzePending(in: imageURLs)
        }
    }

    /// Alive indexed files under `location` (its own row or anything beneath it),
    /// with the real content hashes the indexer just computed. The prefix guard
    /// uses the codebase's `== prefix || hasPrefix(prefix + "/")` rule so a
    /// sibling folder ("/a/Inspo Extra") can't leak into "/a/Inspo".
    private func diskFiles(under location: URL, queue: DatabaseQueue) async -> [DiskFile] {
        let prefix = location.standardizedFileURL.path
        let rows: [(String, String?)] = (try? await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.absolute_path AS path, f.content_hash AS hash
                FROM paths p JOIN files f ON f.id = p.file_id
                WHERE p.is_alive = 1
                """).map { (row: Row) in (row["path"] as String, row["hash"] as String?) }
        }) ?? []
        return rows
            .filter { $0.0 == prefix || $0.0.hasPrefix(prefix + "/") }
            .map { DiskFile(path: $0.0,
                            basename: URL(fileURLWithPath: $0.0).lastPathComponent,
                            contentHash: $0.1) }
    }
}
