//
//  ICloudShareService.swift
//  Muse
//
//  Orchestrates an iCloud collection share: copy the displayed members into
//  Muse's iCloud zone (Shared Collections/<name>/), wait for the OS daemon to
//  finish uploading, record the share, then let the caller present the native
//  share sheet. No network code — the daemon does the sync.
//

import Foundation
import Combine

@MainActor final class ICloudShareService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case copying
        case uploading(UploadTally)
        case ready(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?
    private var query: NSMetadataQuery?
    private let store: ICloudShareStore

    init(store: ICloudShareStore = .default) { self.store = store }

    func reset() {
        cancel()
        phase = .idle
    }

    func cancel() {
        task?.cancel(); task = nil
        stopQuery()
    }

    func start(title: String, urls: [URL]) {
        guard urls.isEmpty == false else {
            phase = .failed(String(localized: "This collection has no images to share."))
            return
        }
        phase = .copying
        task = Task { await run(title: title, urls: urls) }
    }

    private func run(title: String, urls: [URL]) async {
        // Resolve the iCloud zone off the main thread (first access can block).
        guard let docs = await Task.detached(priority: .userInitiated, operation: {
            ICloudZone.folderURL()
        }).value else {
            phase = .failed(String(localized: "Sign in to iCloud and turn on iCloud Drive to share to iCloud."))
            return
        }

        let folder = ICloudSharePaths.shareFolder(zoneDocuments: docs, collectionName: title)
        let copied: [URL]
        do {
            copied = try await Task.detached(priority: .userInitiated) {
                try Self.copyMembers(urls, into: folder)
            }.value
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(String(localized: "Couldn't copy the images into iCloud."))
            return
        }
        if Task.isCancelled { return }
        guard copied.isEmpty == false else {
            phase = .failed(String(localized: "Couldn't copy the images into iCloud."))
            return
        }

        // Record the share now (folder exists); count is what we copied.
        store.add(ICloudShareRecord(id: UUID().uuidString, collectionName: title,
                                    folderPath: folder.path, itemCount: copied.count,
                                    createdAt: Date()))

        phase = .uploading(UploadTally(uploaded: 0, total: copied.count))
        await waitForUpload(of: copied)
        if Task.isCancelled { return }
        phase = .ready(folder)
    }

    /// Refresh the destination (clear + recopy so re-share never piles up
    /// stale files), then copy each member in, downloading dataless sources
    /// first. Returns the destination URLs actually written. Throws on
    /// CancellationError or a fatal filesystem error.
    nonisolated private static func copyMembers(_ urls: [URL], into folder: URL) throws -> [URL] {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var written: [URL] = []
        var usedNames = Set<String>()
        for src in urls {
            if Task.isCancelled { throw CancellationError() }
            // Pull down a not-yet-downloaded iCloud source so the copy has bytes.
            if (try? src.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus == .some(.notDownloaded) {
                try? fm.startDownloadingUbiquitousItem(at: src)
                Self.waitUntilDownloaded(src)
            }
            guard fm.fileExists(atPath: src.path) else { continue }
            // De-collide identical basenames within the share folder.
            var name = src.lastPathComponent
            if usedNames.contains(name) {
                let base = src.deletingPathExtension().lastPathComponent
                let ext = src.pathExtension
                var n = 2
                repeat {
                    name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
                    n += 1
                } while usedNames.contains(name)
            }
            usedNames.insert(name)
            let dest = folder.appendingPathComponent(name)
            do { try fm.copyItem(at: src, to: dest); written.append(dest) }
            catch { continue }
        }
        return written
    }

    /// Block (bounded) until a dataless source finishes downloading. Best-effort:
    /// gives up after ~30s and lets the copy attempt proceed/fail.
    nonisolated private static func waitUntilDownloaded(_ url: URL) {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus
            // Either means local bytes are present and copyable.
            if status == .current || status == .downloaded { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    // MARK: - Upload wait (NSMetadataQuery)

    private func waitForUpload(of copied: [URL]) async {
        let targetPaths = Set(copied.map { $0.standardizedFileURL.path })
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let q = NSMetadataQuery()
            self.query = q
            q.searchScopes = [NSMetadataQueryUbiquitousDataScope]
            q.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
            var resumed = false
            let finish = { [weak self] in
                guard resumed == false else { return }
                resumed = true
                self?.stopQuery()
                cont.resume()
            }
            let onUpdate: (Notification) -> Void = { [weak self] _ in
                guard let self else { return }
                q.disableUpdates()
                var uploadedCount = 0
                for i in 0..<q.resultCount {
                    guard let item = q.result(at: i) as? NSMetadataItem,
                          let p = (item.value(forAttribute: NSMetadataItemPathKey) as? String),
                          targetPaths.contains(URL(fileURLWithPath: p).standardizedFileURL.path)
                    else { continue }
                    if (item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? Bool) ?? false {
                        uploadedCount += 1
                    }
                }
                let tally = UploadTally(uploaded: uploadedCount, total: targetPaths.count)
                self.phase = .uploading(tally)
                q.enableUpdates()
                if tally.isComplete { finish() }
            }
            NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                   object: q, queue: .main, using: onUpdate)
            NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate,
                                                   object: q, queue: .main, using: onUpdate)
            q.start()
        }
    }

    private func stopQuery() {
        if let q = query {
            q.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: q)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: q)
        }
        query = nil
    }
}
