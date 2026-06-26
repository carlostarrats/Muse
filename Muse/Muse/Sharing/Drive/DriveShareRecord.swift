//
//  DriveShareRecord.swift
//  Muse
//
//  Local record of a live Drive share (for the Manage list + the expiry
//  sweeper). JSON in App Support — never Drive, never SQLite.
//

import Foundation

struct DriveShareRecord: Codable, Identifiable, Equatable {
    let id: String
    let collectionName: String
    let folderID: String
    let pageURL: String
    let itemCount: Int
    let createdAt: Date
    let expiry: Date
}

enum DriveExpiry {
    static func expired(_ records: [DriveShareRecord], now: Date) -> [DriveShareRecord] {
        records.filter { $0.expiry < now }
    }
}

final class DriveShareStore {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.tarrats.Muse.driveShareStore")
    init(fileURL: URL) { self.fileURL = fileURL }

    static let `default`: DriveShareStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Muse", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return DriveShareStore(fileURL: base.appendingPathComponent("driveShares.json"))
    }()

    func all() -> [DriveShareRecord] { queue.sync { load().sorted { $0.createdAt > $1.createdAt } } }

    func add(_ r: DriveShareRecord) {
        queue.sync {
            var list = load().filter { $0.id != r.id && $0.folderID != r.folderID }
            list.append(r); save(list)
        }
    }
    func remove(id: String) { queue.sync { save(load().filter { $0.id != id }) } }

    private func load() -> [DriveShareRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder.iso.decode([DriveShareRecord].self, from: data) else { return [] }
        return list
    }
    private func save(_ list: [DriveShareRecord]) {
        guard let data = try? JSONEncoder.iso.encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder { static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }() }
private extension JSONDecoder { static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }() }
