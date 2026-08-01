//
//  ClipModelStore.swift
//  Muse
//
//  Download is STRICTLY user-initiated — never automatic, never at launch.
//  Any failure at any step deletes the partial directory and reports a plain
//  error (fail closed). This is the app's FOURTH sanctioned network path,
//  after Sparkle, the Drive publish, and the announcements channel.
//

import CryptoKit
import Foundation

@MainActor final class ClipModelStore: ObservableObject {
    static let shared = ClipModelStore()

    enum ModelState: Equatable {
        case absent
        case downloading(progress: Double)
        case installed
        case failed(message: String)
    }

    @Published private(set) var state: ModelState = .absent
    private var downloadTask: Task<Void, Never>?

    var isReady: Bool { state == .installed }

    init() {
        probeDisk()
    }

    private func probeDisk() {
        guard let dir = ClipModel.directory() else { return }
        let marker = dir.appendingPathComponent(".verified")
        state = FileManager.default.fileExists(atPath: marker.path) ? .installed : .absent
    }

    func download() {
        switch state {
        case .absent, .failed: break
        case .downloading, .installed: return
        }
        downloadTask = Task { await runDownload() }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        cleanupPartial()
        state = .absent
    }

    func remove() {
        downloadTask?.cancel()
        downloadTask = nil
        cleanupPartial()
        state = .absent
        Task { await ClipEngine.shared.unload() }
    }

    private func cleanupPartial() {
        if let dir = ClipModel.directory() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func runDownload() async {
        state = .downloading(progress: 0)
        let session = URLSession(configuration: .ephemeral)

        // Bounded WHILE reading — `ClipModelManifest.parse` declares a 16 KB
        // ceiling, but checking `data.count` after `session.data(from:)` has
        // already buffered the whole body lets the response choose the
        // allocation. See BoundedBody.
        guard let (manifestData, _) = try? await BoundedBody.data(
                for: URLRequest(url: ClipModel.current.manifestURL),
                session: session,
                limit: ClipModelManifest.maxResponseBytes),
              let manifest = ClipModelManifest.parse(manifestData)
        else {
            state = .failed(message: String(localized: "Couldn't reach the model server. Try again later."))
            return
        }

        guard let dir = ClipModel.directory() else {
            state = .failed(message: String(localized: "Couldn't create the model folder."))
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Streamed to DISK, hashed incrementally. Accumulating the whole
        // archive in a `Data` held a few hundred MB in RAM on the machine the
        // 8 GB reference envelope is measured on — and then wrote the same
        // bytes out anyway. "Never write code that assumes everything fits in
        // RAM" (DECIDED #25) applies to a downloaded artifact as much as to a
        // library.
        let zipPath = dir.appendingPathComponent("model.zip")
        guard let digest = await streamChunks(manifest: manifest, session: session, to: zipPath)
        else {
            // A cancel leaves state alone — cancelDownload()/remove() own it.
            if !Task.isCancelled {
                state = .failed(message: String(localized: "Download failed partway through. Try again."))
                cleanupPartial()
            }
            return
        }

        guard ClipModelManifest.verify(digest: digest, expectedSHA256: manifest.sha256) else {
            state = .failed(message: String(localized: "The downloaded model failed verification."))
            cleanupPartial()
            return
        }

        guard (try? unzip(at: zipPath, into: dir)) != nil else {
            state = .failed(message: String(localized: "The downloaded model couldn't be unpacked."))
            cleanupPartial()
            return
        }

        // Load-test both encoders once before marking verified — an artifact
        // that unpacks but can't load must not leave a ".verified" marker
        // behind for every future launch to trust.
        guard await ClipEngine.shared.canLoad() else {
            state = .failed(message: String(localized: "The model failed to load after install."))
            cleanupPartial()
            return
        }

        FileManager.default.createFile(atPath: dir.appendingPathComponent(".verified").path,
                                       contents: nil)
        state = .installed

        cleanupOlderGenerations(keeping: dir)

        Task { await DeepAnalysisBackfill.run() }
        Task { await ClipPromptVectors.refreshAll() }
    }

    private func cleanupOlderGenerations(keeping current: URL) {
        let modelsRoot = current.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: modelsRoot, includingPropertiesForKeys: nil) else { return }
        for entry in entries
        where entry.lastPathComponent != current.lastPathComponent
            && entry.lastPathComponent.hasPrefix(ClipModel.current.name) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Download every chunk straight to `destination`, hashing as it goes.
    /// Returns the finished digest, or nil if anything failed (the partial
    /// file is removed by the caller's `cleanupPartial`).
    private func streamChunks(manifest: ClipModelManifest, session: URLSession,
                              to destination: URL) async -> SHA256Digest? {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        let base = ClipModel.current.manifestURL.deletingLastPathComponent()
        for (index, chunkName) in manifest.chunks.enumerated() {
            guard !Task.isCancelled else { return nil }
            guard let (chunkData, _) = try? await session.data(
                    from: base.appendingPathComponent(chunkName)),
                  (try? handle.write(contentsOf: chunkData)) != nil
            else { return nil }
            hasher.update(data: chunkData)
            state = .downloading(progress: Double(index + 1) / Double(max(manifest.chunks.count, 1)))
        }
        try? handle.synchronize()
        return hasher.finalize()
    }

    /// Unpacks the verified archive. Throws on any corruption rather than
    /// partially populating `dir` — the caller deletes the whole directory on
    /// a throw, so a half-unpacked model can never be marked verified.
    private func unzip(at zipPath: URL, into dir: URL) throws {
        defer { try? FileManager.default.removeItem(at: zipPath) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipPath.path, "-d", dir.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ClipModelStore", code: 1)
        }
    }
}
