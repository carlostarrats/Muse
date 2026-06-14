//
//  ICloudZone.swift
//  Muse
//
//  The single app-managed iCloud Drive folder. Files placed in its
//  `Documents` directory sync across the user's devices via the OS daemon
//  (no app network calls). One folder only — the user may create their
//  own subfolders inside it.
//

import Foundation

nonisolated enum ICloudZone {
    static let containerID = "iCloud.com.tarrats.Muse"

    /// The synced "Muse" folder URL (the container's Documents dir), creating
    /// it if needed. Returns nil if the user isn't signed into iCloud or the
    /// container is unavailable. Call off the main thread — first access can
    /// block while the daemon resolves the container.
    static func folderURL() -> URL? {
        guard let container = FileManager.default
                .url(forUbiquityContainerIdentifier: containerID) else { return nil }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    /// True if `url` lives inside the iCloud zone. Cheap path-prefix test
    /// against a resolved folder URL (pass the cached `folderURL()` in).
    static func contains(_ url: URL, folder: URL?) -> Bool {
        guard let folder else { return false }
        let f = folder.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p == f || p.hasPrefix(f + "/")
    }
}
