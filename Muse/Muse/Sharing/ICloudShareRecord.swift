//
//  ICloudShareRecord.swift
//  Muse
//
//  A record of one iCloud collection share Muse made (so the user can later
//  delete the folder and reclaim space). JSON-backed list in Application
//  Support — NOT in iCloud, NOT SQLite (corruption trap).
//

import Foundation

struct ICloudShareRecord: Codable, Identifiable, Equatable {
    let id: String
    let collectionName: String
    let folderPath: String
    let itemCount: Int
    let createdAt: Date
    /// The owning collection's STABLE id (optional: older records predate this
    /// field and decode to nil). Used to disambiguate share folders so two
    /// collections with the same display name can't clobber each other's folder.
    /// Falls back to `collectionName` as the identity when absent.
    var collectionID: String? = nil

    /// Identity used for folder-ownership comparisons: the stable id when known,
    /// otherwise the display name (legacy records).
    var identity: String { collectionID ?? collectionName }
}

final class ICloudShareStore {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.tarrats.Muse.icloudShareStore")

    init(fileURL: URL) { self.fileURL = fileURL }

    static let `default`: ICloudShareStore = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Muse", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return ICloudShareStore(fileURL: base.appendingPathComponent("iCloudShares.json"))
    }()

    /// Records newest-first.
    func all() -> [ICloudShareRecord] {
        queue.sync { load().sorted { $0.createdAt > $1.createdAt } }
    }

    /// Add (or replace). Re-sharing a collection reuses the same folder path,
    /// so drop any prior record for that folder — otherwise the Manage list
    /// would show stale duplicates that point at the same (deletable) folder.
    func add(_ r: ICloudShareRecord) {
        queue.sync {
            var list = load().filter { $0.id != r.id && $0.folderPath != r.folderPath }
            list.append(r)
            save(list)
        }
    }

    func remove(id: String) {
        queue.sync { save(load().filter { $0.id != id }) }
    }

    /// Drop records whose folder is gone, per `exists`, and return the survivors
    /// (newest-first). Rewrites the store only when something was actually
    /// pruned. The predicate runs on the store's serial queue. CALLER CONTRACT:
    /// only call this when iCloud is reachable (resolvable zone) — otherwise a
    /// temporarily-unavailable container would read as "all folders missing" and
    /// prune live shares. This drops only the local RECORD, never any file.
    func pruneMissing(exists: (ICloudShareRecord) -> Bool) -> [ICloudShareRecord] {
        queue.sync {
            let all = load()
            let kept = all.filter(exists)
            if kept.count != all.count { save(kept) }
            return kept.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func load() -> [ICloudShareRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder.iso.decode([ICloudShareRecord].self, from: data)
        else { return [] }
        return list
    }

    private func save(_ list: [ICloudShareRecord]) {
        guard let data = try? JSONEncoder.iso.encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}
private extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
