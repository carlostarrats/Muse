//
//  AppState+Backup.swift
//  Muse
//
//  Library backup & restore (2026-06-20 library-backup spec). Extracted from
//  AppState.swift in the 2026-06-20 code-health refactor — methods only;
//  all stored state stays in the core AppState file.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
extension AppState {
    // MARK: - Backup & restore (2026-06-20 library-backup spec)

    /// Export a one-file backup of the whole library (folders, collections,
    /// tags, stars, AI metadata) re-keyed to content hash. Purely additive;
    /// reads the DB, writes a `.muselibrary` file the user keeps and carries.
    func exportBackup() {
        guard let queue = Database.shared.dbQueue else { return }
        let roots: [BackupRoot] = bookmarks.roots.compactMap { root in
            guard let url = bookmarks.url(for: root) else { return nil }
            return BackupRoot(path: url.standardizedFileURL.path,
                              display_name: url.lastPathComponent)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let suggested = "Muse Backup \(formatter.string(from: Date())).\(BackupDocument.fileExtension)"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.canCreateDirectories = true
        panel.message = String(localized: "Keep this file somewhere safe — ideally not only on this Mac. You'll use it to restore your collections, tags, and folders on another Mac.")
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        Task {
            do {
                let archive = try await BackupBuilder.build(
                    queue: queue, roots: roots,
                    createdAt: Int64(Date().timeIntervalSince1970), appVersion: version)
                // Encode + write OFF the main actor. This `Task` inherits
                // AppState's MainActor isolation, so the JSON encode of a whole
                // library — tens of MB for a real collection — and the disk
                // write both landed on the main thread, freezing the app after
                // the save panel had already closed.
                try await Task.detached(priority: .userInitiated) {
                    let data = try BackupDocument.encode(archive)
                    try data.write(to: dest, options: .atomic)
                }.value
            } catch {
                print("[Backup] export failed: \(error)")
                backupError = String(localized: "The backup couldn’t be saved. Check that the location is writable and has enough free space, then try again.")
            }
        }
    }

    /// Pick a `.muselibrary` file and open the Reconnect wizard.
    func beginRestorePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: BackupDocument.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.message = String(localized: "Choose the Muse backup file you exported on your other Mac.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Read + JSON-decode OFF the main actor. A `.muselibrary` describes a
        // whole library — every file's tags, note, edit stack, versions and the
        // LUT blobs — so it is tens of MB of JSON for a real collection, and
        // decoding it inline froze the app between the panel closing and the
        // wizard appearing, which reads as a hang with nothing on screen.
        Task { [weak self] in
            do {
                let archive = try await Task.detached(priority: .userInitiated) {
                    let data = try Data(contentsOf: url)
                    return try BackupDocument.decode(data)
                }.value
                guard let self else { return }
                self.reconnectModel = ReconnectModel(archive: archive)
                self.reconnectShown = true
            } catch {
                print("[Backup] restore load failed: \(error)")
                self?.backupError = String(localized: "That file couldn’t be opened as a Muse backup. It may be the wrong file, or damaged.")
            }
        }
    }
}
