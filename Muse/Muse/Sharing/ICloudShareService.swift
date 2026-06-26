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
    /// The most recent detached copy task. A detached task does NOT observe this
    /// service's cancellation, so a superseded/double-tapped run's copy keeps
    /// running; the next run chains on this handle so two copies never race
    /// `removeItem`/recopy on the same folder (which would corrupt the gallery).
    private var inFlightCopy: Task<[URL], Error>?
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

    func start(title: String, collectionID: String, urls: [URL]) {
        guard urls.isEmpty == false else {
            phase = .failed(String(localized: "This collection has no images to share."))
            return
        }
        // Supersede any in-flight run: tear down a prior upload wait (resume its
        // continuation, stop its query) so starting a second share never strands
        // the old run on an overwritten continuation or leaks its NSMetadataQuery.
        cancel()
        generation &+= 1
        let gen = generation
        phase = .copying
        task = Task { await run(title: title, collectionID: collectionID, urls: urls, gen: gen) }
    }

    private func run(title: String, collectionID: String, urls: [URL], gen: Int) async {
        // Resolve the iCloud zone off the main thread (first access can block).
        guard let docs = await Task.detached(priority: .userInitiated, operation: {
            ICloudZone.folderURL()
        }).value else {
            if gen == generation {
                phase = .failed(String(localized: "Sign in to iCloud and turn on iCloud Drive to share to iCloud."))
            }
            return
        }

        // Disambiguate against other collections' live shares so a name that
        // sanitizes to an already-used folder never reuses (and clobbers) it.
        let owners = Dictionary(
            store.all().map { (URL(fileURLWithPath: $0.folderPath).lastPathComponent, $0.identity) },
            uniquingKeysWith: { first, _ in first })
        let leaf = ICloudSharePaths.uniqueFolderName(for: title, identity: collectionID, owners: owners)
        let folder = ICloudSharePaths.shareRoot(zoneDocuments: docs)
            .appendingPathComponent(leaf, isDirectory: true)
        let shareRoot = ICloudSharePaths.shareRoot(zoneDocuments: docs)
        let copied: [URL]
        do {
            // Serialize the destructive copy across runs: capture the prior copy
            // and store ours SYNCHRONOUSLY (no await between), so two runs can't
            // both launch on one folder. The chain waits inside the detached task.
            let prior = inFlightCopy
            let copyTask = Task.detached(priority: .userInitiated) { () -> [URL] in
                _ = try? await prior?.value
                return try Self.copyMembers(urls, into: folder, shareRoot: shareRoot)
            }
            inFlightCopy = copyTask
            copied = try await copyTask.value
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
                                    createdAt: Date(), collectionID: collectionID))

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
    nonisolated private static func copyMembers(_ urls: [URL], into folder: URL,
                                                shareRoot: URL) throws -> [URL] {
        let fm = FileManager.default
        // Defense-in-depth before the destructive `removeItem`: the share folder
        // must be a direct, non-special child of the share root. Backstops a
        // sanitizer gap (a `.`/`..` leaf would make `removeItem` delete the
        // PARENT — the whole iCloud Documents zone). The sanitizer already
        // prevents this, so a real share never trips the guard.
        guard ICloudSharePaths.isContainedShareFolder(folder, shareRoot: shareRoot)
        else { throw CocoaError(.fileWriteInvalidFileName) }
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
