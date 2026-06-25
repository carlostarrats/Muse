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
    private var observerTokens: [NSObjectProtocol] = []
    private var uploadContinuation: CheckedContinuation<Void, Never>?
    /// Bumped only when a NEW share starts. A run captures its value and
    /// touches shared state (phase/folder/store) only while still current —
    /// so a superseded run can't delete the live run's folder or clobber its
    /// phase. NOT bumped on cancel, so a plain cancel still cleans up its own
    /// folder (the copy ran in a detached task that can't see cancellation).
    private var generation = 0
    private let store: ICloudShareStore

    init(store: ICloudShareStore = .default) { self.store = store }

    func reset() {
        cancel()
        phase = .idle
    }

    func cancel() {
        task?.cancel(); task = nil
        tearDownUploadWait()
    }

    func start(title: String, urls: [URL]) {
        guard urls.isEmpty == false else {
            phase = .failed(String(localized: "This collection has no images to share."))
            return
        }
        generation &+= 1
        let gen = generation
        phase = .copying
        task = Task { await run(title: title, urls: urls, gen: gen) }
    }

    private func run(title: String, urls: [URL], gen: Int) async {
        // Resolve the iCloud zone off the main thread (first access can block).
        guard let docs = await Task.detached(priority: .userInitiated, operation: {
            ICloudZone.folderURL()
        }).value else {
            if gen == generation {
                phase = .failed(String(localized: "Sign in to iCloud and turn on iCloud Drive to share to iCloud."))
            }
            return
        }

        let folder = ICloudSharePaths.shareFolder(zoneDocuments: docs, collectionName: title)
        let copied: [URL]
        do {
            copied = try await Task.detached(priority: .userInitiated) {
                try Self.copyMembers(urls, into: folder)
            }.value
        } catch is CancellationError {
            if gen == generation { Self.cleanup(folder) }
            return
        } catch {
            guard gen == generation else { return }
            Self.cleanup(folder)
            phase = .failed(String(localized: "Couldn't copy the images into iCloud."))
            return
        }
        // Superseded by a newer share → leave the folder for the new run (which
        // recreates it) and don't touch phase/store.
        guard gen == generation else { return }
        if Task.isCancelled { Self.cleanup(folder); return }
        guard copied.isEmpty == false else {
            Self.cleanup(folder)
            phase = .failed(String(localized: "Couldn't copy the images into iCloud."))
            return
        }

        // Record the share now (folder exists); count is what we copied.
        store.add(ICloudShareRecord(id: UUID().uuidString, collectionName: title,
                                    folderPath: folder.path, itemCount: copied.count,
                                    createdAt: Date()))

        phase = .uploading(UploadTally(uploaded: 0, total: copied.count))
        await waitForUpload(of: copied)
        // Folder is recorded now, so a cancel here keeps it (deletable in Manage).
        if Task.isCancelled || gen != generation { return }
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
            let name = ICloudSharePaths.uniqueName(src.lastPathComponent, taken: usedNames)
            usedNames.insert(name)
            let dest = folder.appendingPathComponent(name)
            do { try fm.copyItem(at: src, to: dest); written.append(dest) }
            catch { continue }
        }
        return written
    }

    /// Best-effort removal of a partially-built share folder (cancel / failure
    /// paths) so we never orphan an untracked folder in the iCloud container.
    nonisolated private static func cleanup(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
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
        // Resolve symlinks on both sides — the ubiquity container can be reached
        // through a symlinked root, so standardized paths alone may never match
        // the metadata item's path (which would hang the wait forever).
        let targetPaths = Set(copied.map { $0.resolvingSymlinksInPath().path })
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.uploadContinuation = cont
            let q = NSMetadataQuery()
            self.query = q
            // Files live in the container's Documents dir → the Documents scope,
            // NOT the Data scope (which is everything OUTSIDE Documents).
            q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            q.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
            let onUpdate: (Notification) -> Void = { [weak self] _ in
                guard let self else { return }
                q.disableUpdates()
                var uploadedCount = 0
                for i in 0..<q.resultCount {
                    guard let item = q.result(at: i) as? NSMetadataItem,
                          let p = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                          targetPaths.contains(URL(fileURLWithPath: p).resolvingSymlinksInPath().path)
                    else { continue }
                    if (item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? Bool) ?? false {
                        uploadedCount += 1
                    }
                }
                self.phase = .uploading(UploadTally(uploaded: uploadedCount, total: targetPaths.count))
                q.enableUpdates()
                if uploadedCount == targetPaths.count { self.tearDownUploadWait() }
            }
            // addObserver(forName:…using:) registers an opaque TOKEN, not `self`
            // — keep the tokens so we can actually remove them later.
            observerTokens = [
                NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                       object: q, queue: .main, using: onUpdate),
                NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate,
                                                       object: q, queue: .main, using: onUpdate),
            ]
            q.start()
        }
    }

    /// Stop the query, drop its observers, and resume the upload-wait
    /// continuation exactly once — so cancelling mid-upload never leaks it.
    /// Safe to call repeatedly (idempotent).
    private func tearDownUploadWait() {
        query?.stop()
        observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
        observerTokens = []
        query = nil
        if let c = uploadContinuation { uploadContinuation = nil; c.resume() }
    }
}
