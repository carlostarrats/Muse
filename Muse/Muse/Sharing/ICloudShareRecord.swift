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

    func add(_ r: ICloudShareRecord) {
        queue.sync {
            var list = load().filter { $0.id != r.id }
            list.append(r)
            save(list)
        }
    }

    func remove(id: String) {
        queue.sync { save(load().filter { $0.id != id }) }
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
