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
    /// `var` so a portfolio update can mutate the record in place and re-add it
    /// (same id/pageURL/folderID/createdAt — the update never mints a new URL).
    var itemCount: Int
    let createdAt: Date
    var expiry: Date                    // `.neverExpires` sentinel for portfolios
    // Spec 07 — all optional so a pre-existing driveShares.json decodes unchanged.
    var kind: String? = nil             // "portfolio"; nil/anything else = classic share
    var manifestFileID: String? = nil   // the stable pointer (files.update target)
    var collectionID: String? = nil     // binds "Update Portfolio…" to its collection
    var layout: String? = nil           // prefill for the update form
    var introTitle: String? = nil       // prefill
    var bodyText: String? = nil         // prefill

    var isPortfolio: Bool { kind == "portfolio" }

    /// 2100-01-01T00:00:00Z. A SENTINEL, not an optional: an optional expiry
    /// would make new-format records undecodable by the previous build's
    /// non-optional field, and that build's failed `load()` silently drops the
    /// WHOLE share list on its next save. The sentinel keeps older builds fully
    /// working, and the sweeper needs no portfolio special case — `expiry < now`
    /// is simply never true.
    static let neverExpires = Date(timeIntervalSince1970: 4_102_444_800)
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

    /// `nonisolated`: reached from the Drive publish/sweep tasks, which run
    /// off the main actor.
    nonisolated static let `default`: DriveShareStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Muse", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return DriveShareStore(fileURL: base.appendingPathComponent("driveShares.json"))
    }()

    func all() -> [DriveShareRecord] { queue.sync { load().sorted { $0.createdAt > $1.createdAt } } }

    /// The lookup seam binding "Update Portfolio…" to its collection, newest
    /// first (the menu offers the latest).
    func portfolio(forCollectionID id: String) -> [DriveShareRecord] {
        queue.sync {
            load().filter { $0.isPortfolio && $0.collectionID == id }
                  .sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// Returns whether the record was persisted. The caller (DriveShareService)
    /// uses this to warn when a live, public share couldn't be saved to the
    /// local list — without a record, Manage/expiry-sweep can never find or
    /// unpublish it, so the user must copy the link before dismissing.
    @discardableResult
    func add(_ r: DriveShareRecord) -> Bool {
        queue.sync {
            var list = load().filter { $0.id != r.id && $0.folderID != r.folderID }
            list.append(r); return save(list)
        }
    }
    func remove(id: String) { queue.sync { _ = save(load().filter { $0.id != id }) } }

    /// Drop several records in one rewrite (used by the Manage prune). No-op if
    /// `ids` is empty so it never rewrites the file needlessly.
    func remove(ids: [String]) {
        guard ids.isEmpty == false else { return }
        let drop = Set(ids)
        queue.sync { _ = save(load().filter { drop.contains($0.id) == false }) }
    }

    private func load() -> [DriveShareRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder.iso.decode([DriveShareRecord].self, from: data) else { return [] }
        return list
    }
    @discardableResult
    private func save(_ list: [DriveShareRecord]) -> Bool {
        guard let data = try? JSONEncoder.iso.encode(list) else { return false }
        do { try data.write(to: fileURL, options: .atomic); return true }
        catch { return false }
    }
}

private extension JSONEncoder { static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }() }
private extension JSONDecoder { static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }() }
