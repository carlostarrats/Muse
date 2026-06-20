//
//  ReconnectModel.swift
//  Muse
//
//  Drives the Reconnect wizard. Maps each backed-up folder to a new location,
//  then (on Reconnect All) indexes + hashes each, matches occurrences by
//  content hash, applies metadata, and finally materializes collections + stars.
//  All heavy lifting delegates to the pure matcher/materializer/applier.
//

import Foundation
import SwiftUI
import GRDB

@MainActor
final class ReconnectModel: ObservableObject {
    enum FolderStatus: Equatable {
        case pending, working, clean, flagged(unmatched: Int)
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
    @Published var isRunning = false
    @Published var finished = false

    private let archive: BackupArchive
    private let hashToFile: [String: BackupFile]
    private let hashForOriginalPath: [String: String]
    private var cancelled = false

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

    func autoMap(parent: URL) {
        let fm = FileManager.default
        for i in folders.indices {
            let candidate = parent.appendingPathComponent(folders[i].displayName, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                folders[i].newLocation = candidate
            }
        }
    }

    func setLocation(_ url: URL, forFolder id: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].newLocation = url
    }

    func cancel() {
        cancelled = true
        isRunning = false
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

    func reconnectAll(bookmarks: BookmarkStore) async {
        guard let queue = Database.shared.dbQueue else { return }
        cancelled = false
        isRunning = true
        finished = false

        var addedImageURLs: [URL] = []

        for i in folders.indices {
            if cancelled { break }
            guard let location = folders[i].newLocation else { continue }
            folders[i].status = .working

            _ = bookmarks.addRoot(at: location)

            // Enumerate the folder's indexable files off the main actor.
            let (pairs, imageURLs) = await Task.detached(priority: .utility) {
                () -> (pairs: [(URL, AssetKind)], images: [URL]) in
                var pairs: [(URL, AssetKind)] = []
                var images: [URL] = []
                let fm = FileManager.default
                guard let en = fm.enumerator(at: location, includingPropertiesForKeys: [.isRegularFileKey])
                else { return ([], []) }
                for case let url as URL in en {
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                    else { continue }
                    let kind = AssetKind.detect(at: url)
                    guard kind != .folder, kind.hasNativeViewer || kind == .archive else { continue }
                    pairs.append((url, kind))
                    if kind == .image || kind == .raw || kind == .psd { images.append(url) }
                }
                return (pairs, images)
            }.value

            // Index the folder through the real pipeline — this is what creates
            // the FileRow (by content hash) + PathRow that applyMeta/collections
            // join against. Reuses the exact identity machinery the app uses.
            _ = await Indexer.shared.indexBatch(pairs, priority: .high)
            addedImageURLs.append(contentsOf: imageURLs)

            // Read the now-indexed disk files back (their real content hashes) and
            // match the archive's occurrences for this folder against them.
            let disk = await diskFiles(under: location, queue: queue)
            let rootID = folders[i].id
            let occurrences = archive.files.flatMap { $0.occurrences }
                .filter { $0.root_path == rootID }
            let expected = Dictionary(uniqueKeysWithValues:
                occurrences.compactMap { o -> (String, String)? in
                    guard let h = hashForOriginalPath[o.original_path] else { return nil }
                    return (o.original_path, h)
                })
            let match = ReconnectMatcher.match(occurrences: occurrences, disk: disk,
                                               expectedHash: expected)

            // Apply metadata per backup file.
            var byFile: [String: [OccurrenceMatch]] = [:]
            for m in match.matches {
                guard let h = hashForOriginalPath[m.occurrence.original_path] else { continue }
                byFile[h, default: []].append(m)
            }
            for (hash, matches) in byFile {
                guard let file = hashToFile[hash] else { continue }
                try? await ReconnectApplier.applyMeta(matches: matches, file: file, queue: queue)
            }

            folders[i].status = match.unmatched.isEmpty ? .clean
                : .flagged(unmatched: match.unmatched.count)
        }

        // Collections + stars from the now-populated DB.
        if let map = try? await ReconnectApplier.currentFileIDForHash(queue: queue) {
            try? await ReconnectApplier.applyCollections(archive, fileIDForHash: map, queue: queue)
            try? await ReconnectApplier.applyStars(archive, queue: queue)
            for j in collectionStatuses.indices {
                let coll = archive.collections.first { $0.id == collectionStatuses[j].id }
                collectionStatuses[j].reconnected = coll?.members
                    .filter { map[$0.content_hash] != nil }.count ?? 0
            }
        }

        // Reconcile: analyze anything new/changed the backup didn't cover.
        if !addedImageURLs.isEmpty {
            await AnalyzePipeline.shared.analyzePending(in: addedImageURLs)
        }

        isRunning = false
        finished = true
    }
}
