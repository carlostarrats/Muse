//
//  ClipModelStore.swift
//  Muse
//
//  Download is STRICTLY user-initiated — never automatic, never at launch.
//  Any failure at any step deletes the partial directory and reports a plain
//  error (fail closed). This is the app's FOURTH sanctioned network path,
//  after Sparkle, the Drive publish, and the announcements channel.
//

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

        guard let (manifestData, _) = try? await session.data(from: ClipModel.current.manifestURL),
              let manifest = ClipModelManifest.parse(manifestData)
        else {
            state = .failed(message: String(localized: "Couldn't reach the model server. Try again later."))
            return
        }

        var assembled = Data()
        let base = ClipModel.current.manifestURL.deletingLastPathComponent()
        for (index, chunkName) in manifest.chunks.enumerated() {
            guard !Task.isCancelled else { return }
            guard let (chunkData, _) = try? await session.data(from: base.appendingPathComponent(chunkName))
            else {
                state = .failed(message: String(localized: "Download failed partway through. Try again."))
                cleanupPartial()
                return
            }
            assembled.append(chunkData)
            state = .downloading(progress: Double(index + 1) / Double(max(manifest.chunks.count, 1)))
        }

        guard ClipModelManifest.verify(assembled: assembled, expectedSHA256: manifest.sha256) else {
            state = .failed(message: String(localized: "The downloaded model failed verification."))
            cleanupPartial()
            return
        }

        guard let dir = ClipModel.directory() else {
            state = .failed(message: String(localized: "Couldn't create the model folder."))
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? unzip(assembled, into: dir)) != nil else {
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

    /// Unpacks the verified archive. Throws on any corruption rather than
    /// partially populating `dir` — the caller deletes the whole directory on
    /// a throw, so a half-unpacked model can never be marked verified.
    private func unzip(_ data: Data, into dir: URL) throws {
        let zipPath = dir.appendingPathComponent("model.zip")
        try data.write(to: zipPath)
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
