//
//  ApplePhotosImportModel.swift
//  Muse
//
//  Apple Photos → a folder of ordinary files.
//
//  The supported path is the RENDERED current version, stated plainly. Apple's
//  `PHAdjustmentData` is a zlib'd binary plist with no published spec — even
//  osxphotos, which decodes it, doesn't interpret it. Pretending to recover
//  sliders from it would be the exact "never pretend a translation is
//  lossless" failure this whole surface exists to avoid, so Muse doesn't try
//  and says so in the report.
//
//  PhotoKit's iCloud fetches (`isNetworkAccessAllowed`) are OS-mediated system
//  traffic — the StoreKit/`bird` doctrine class — not an app network path. The
//  app itself opens no connection.
//

import Foundation
import Photos
import GRDB
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ApplePhotosImportModel: ObservableObject {

    enum Phase: Equatable {
        case options
        case requestingAccess
        case denied
        case running(done: Int, total: Int)
        case done(report: ImportReport)
    }

    @Published private(set) var phase: Phase = .options
    @Published var recreateAlbums = true
    /// Default TAG, never a star: a favorite is a binary flag, and turning one
    /// into a rating would fabricate a judgement the user never made.
    @Published var favoritesAsTag = true

    nonisolated static let favoriteTag = "Favorite"

    private var task: Task<Void, Never>?

    func start(destination: URL, appState: AppState) {
        guard task == nil else { return }
        let albums = recreateAlbums
        let favorites = favoritesAsTag
        task = Task { [weak self, weak appState] in
            guard let self else { return }
            await self.run(destination: destination, appState: appState,
                           recreateAlbums: albums, favoritesAsTag: favorites)
        }
    }

    func cancel() { task?.cancel() }

    private func run(destination: URL, appState: AppState?,
                     recreateAlbums: Bool, favoritesAsTag: Bool) async {
        var report = ImportReport(sourceName: String(localized: "Apple Photos"))
        report.notices.append(String(localized: "Apple Photos edits are applied to the imported image; the individual adjustments can't be recovered (private format)."))
        report.notices.append(String(localized: "Keywords assigned in Photos aren't available to other apps and were not imported."))

        phase = .requestingAccess
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            phase = .denied
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: options)
        phase = .running(done: 0, total: assets.count)

        var written: [(asset: PHAsset, url: URL)] = []
        var usedNames = Set<String>()
        for index in 0..<assets.count {
            if Task.isCancelled { break }
            phase = .running(done: index, total: assets.count)
            let asset = assets.object(at: index)
            guard asset.mediaType == .image || asset.mediaType == .video else { continue }
            switch await export(asset: asset, into: destination, used: &usedNames) {
            case .written(let url):
                report.filesImported += 1
                written.append((asset, url))
            case .skipped(let url):
                report.filesSkipped += 1
                written.append((asset, url))
            case .failed:
                report.filesSkipped += 1
            }
        }
        if Task.isCancelled { return }

        var batch: [(URL, AssetKind)] = []
        for entry in written {
            batch.append((entry.url, AssetKind.detect(at: entry.url)))
            if batch.count >= 50 {
                _ = await Indexer.shared.indexBatch(batch, priority: .high)
                batch = []
            }
        }
        if !batch.isEmpty { _ = await Indexer.shared.indexBatch(batch, priority: .high) }

        guard let queue = Database.shared.dbQueue else {
            finish(report, appState: appState)
            return
        }

        var appliedSupplement = false
        var fileIDByLocalID: [String: String] = [:]
        for entry in written {
            if Task.isCancelled { break }
            let absPath = entry.url.standardizedFileURL.path
            let header = await PhotoHeaderReader.read(url: entry.url,
                                                      kind: AssetKind.detect(at: entry.url))
            let coordinate = entry.asset.location?.coordinate
            let captureDate = entry.asset.creationDate.map { Int64($0.timeIntervalSince1970) }
            let favorite = favoritesAsTag && entry.asset.isFavorite
            // Returned FROM the @Sendable write closure rather than assigned
            // into captured `var`s — a data race the Swift 6 language mode
            // rejects outright.
            nonisolated struct EntryOutcome {
                var applied = ImportSupplement.AppliedFields()
                var fileID: String?
            }
            let outcome: EntryOutcome = (try? await queue.write { db -> EntryOutcome in
                var out = EntryOutcome()
                guard let scope = try MetadataImportApply.scope(db: db, absPath: absPath),
                      let row = try FileRow.filter(FileRow.Columns.id == scope.fileID)
                        .fetchOne(db), let hash = row.content_hash else { return out }
                out.fileID = scope.fileID
                out.applied = try ImportSupplement.apply(
                    db: db, fileID: scope.fileID, contentHash: hash, header: header,
                    external: .init(lat: coordinate?.latitude, lon: coordinate?.longitude,
                                    captureDate: captureDate))
                if favorite {
                    try MetadataImportApply.applyKeywords(db: db, scope: scope,
                                                          labels: [Self.favoriteTag])
                }
                return out
            }) ?? EntryOutcome()
            if let fid = outcome.fileID {
                fileIDByLocalID[entry.asset.localIdentifier] = fid
            }
            if outcome.applied.coordinates { report.coordinates += 1; appliedSupplement = true }
            if outcome.applied.captureDate { report.captureDates += 1; appliedSupplement = true }
            if favorite { report.keywords += 1 }
            report.filesTouched += 1
        }

        if recreateAlbums, !fileIDByLocalID.isEmpty {
            report.collectionsCreated += await recreate(albums: fileIDByLocalID, queue: queue)
            await CollectionsEngine.shared.reload()
        }
        if appliedSupplement {
            Task {
                await GeocodeBackfill.run()
                await SearchFacets.shared.refresh()
            }
        }
        appState?.tagsVersion += 1
        finish(report, appState: appState)
    }

    private func finish(_ report: ImportReport, appState: AppState?) {
        phase = .done(report: report)
        appState?.importModal = .report(report)
    }

    // MARK: - Export

    private enum ExportResult {
        case written(URL)
        /// Already at the destination from a prior run — idempotent.
        case skipped(URL)
        case failed
    }

    private func export(asset: PHAsset, into destination: URL,
                        used: inout Set<String>) async -> ExportResult {
        let resources = PHAssetResource.assetResources(for: asset)
        let originalName = resources.first?.originalFilename
            ?? "\(asset.localIdentifier.prefix(8)).jpg"
        if asset.mediaType == .image {
            guard let payload = await imageData(for: asset) else { return .failed }
            let stem = (originalName as NSString).deletingPathExtension
            let ext = payload.extension ?? (originalName as NSString).pathExtension
            let target = destination.appendingPathComponent(
                ext.isEmpty ? stem : "\(stem).\(ext)")
            if FileManager.default.fileExists(atPath: target.path) { return .skipped(target) }
            let name = Self.collisionName(base: stem, ext: ext, existing: used)
            used.insert(name.lowercased())
            let finalURL = destination.appendingPathComponent(name)
            do {
                // `.withoutOverwriting`: the `fileExists` check above is a
                // moment old, and an import writes into a folder the user
                // chose — quite possibly one another app is also writing to.
                // An atomic write would silently replace whatever landed there
                // in between; this one fails that single photo instead, which
                // the report already knows how to say. (Never pair this flag
                // with `.atomic` — Foundation traps on the combination.)
                try payload.data.write(to: finalURL, options: .withoutOverwriting)
                return .written(finalURL)
            } catch {
                return .failed
            }
        }
        // Video: stream the full-size resource rather than transcoding it.
        let resource = resources.first { $0.type == .fullSizeVideo }
            ?? resources.first { $0.type == .video }
        guard let resource else { return .failed }
        let target = destination.appendingPathComponent(resource.originalFilename)
        if FileManager.default.fileExists(atPath: target.path) { return .skipped(target) }
        let stem = (resource.originalFilename as NSString).deletingPathExtension
        let ext = (resource.originalFilename as NSString).pathExtension
        let name = Self.collisionName(base: stem, ext: ext, existing: used)
        used.insert(name.lowercased())
        let finalURL = destination.appendingPathComponent(name)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await PHAssetResourceManager.default()
                .writeData(for: resource, toFile: finalURL, options: options)
            return .written(finalURL)
        } catch {
            return .failed
        }
    }

    private func imageData(for asset: PHAsset) async -> (data: Data, extension: String?)? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options) { data, uti, _, _ in
                guard let data else { return continuation.resume(returning: nil) }
                // The returned UTI is the authority — Photos may hand back a
                // JPEG for an asset whose original filename says HEIC.
                let ext = uti.flatMap { UTType($0)?.preferredFilenameExtension }
                continuation.resume(returning: (data, ext))
            }
        }
    }

    /// "IMG_0001" + "jpg" → "IMG_0001 2.jpg" when taken, case-insensitively.
    nonisolated static func collisionName(base: String, ext: String,
                                          existing: Set<String>) -> String {
        func compose(_ stem: String) -> String { ext.isEmpty ? stem : "\(stem).\(ext)" }
        let lowered = Set(existing.map { $0.lowercased() })
        if !lowered.contains(compose(base).lowercased()) { return compose(base) }
        var index = 2
        while lowered.contains(compose("\(base) \(index)").lowercased()) { index += 1 }
        return compose("\(base) \(index)")
    }

    // MARK: - Albums

    /// User albums only — a smart album is a rule Muse can't honour, and
    /// materializing its current members as a manual collection would silently
    /// freeze something the user expects to keep updating.
    private func recreate(albums fileIDByLocalID: [String: String],
                          queue: DatabaseQueue) async -> Int {
        var created = 0
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil)
        for index in 0..<collections.count {
            if Task.isCancelled { break }
            let album = collections.object(at: index)
            guard let name = album.localizedTitle?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            let assets = PHAsset.fetchAssets(in: album, options: nil)
            var memberIDs: [String] = []
            for assetIndex in 0..<assets.count {
                let localID = assets.object(at: assetIndex).localIdentifier
                if let fileID = fileIDByLocalID[localID] { memberIDs.append(fileID) }
            }
            guard let first = memberIDs.first else { continue }
            let existing = try? await queue.read { db in
                try String.fetchOne(db, sql:
                    "SELECT id FROM collections WHERE name = ? COLLATE NOCASE AND is_hidden = 0",
                    arguments: [name])
            }
            let collectionID: String?
            if let existing = existing ?? nil {
                collectionID = existing
            } else {
                collectionID = try? await CollectionStore.createManual(
                    queue: queue, name: name, fileID: first)
                if collectionID != nil { created += 1 }
            }
            guard let collectionID else { continue }
            for fileID in memberIDs {
                try? await CollectionStore.addFile(queue: queue, fileID: fileID,
                                                   collectionID: collectionID)
            }
        }
        return created
    }
}
