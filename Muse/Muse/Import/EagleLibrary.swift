//
//  EagleLibrary.swift
//  Muse
//
//  Reader for an Eagle `.library` package.
//
//  Layout (as Eagle writes it):
//
//    <name>.library/
//      metadata.json                     ← folder tree (nested `children`)
//      images/
//        <id>.info/
//          metadata.json                 ← per-item: name, ext, tags, folders,
//          <name>.<ext>                    star, annotation
//
//  Tolerant PER ITEM by design: a corrupt item is skipped and counted, never
//  fatal to the run — one bad row in someone's 40,000-item library must not
//  cost them the other 39,999.
//
//  Dropped deliberately (per the approved design in
//  docs/future-features/eagle-library-import.md): source URLs, smart folders,
//  Eagle's own palette data. Annotations DO come across as notes — that
//  document said "dropped", but it predates the v11 notes table.
//

import Foundation

nonisolated struct EagleItem: Equatable, Sendable {
    var id: String
    var fileURL: URL
    var name: String
    var tags: [String] = []
    var star: Int?
    var annotation: String?
    var folderIDs: [String] = []
}

nonisolated struct EagleFolder: Equatable, Sendable {
    var id: String
    var name: String
    var childIDs: [String]
}

nonisolated enum EagleLibrary {

    /// Joins a nested folder path. En dash, matching how the rest of the app
    /// renders composed names.
    static let nestingSeparator = " – "

    static func read(at libraryURL: URL) throws -> (items: [EagleItem], folders: [EagleFolder]) {
        let folders = readFolders(at: libraryURL)
        let items = readItems(at: libraryURL)
        return (items, folders)
    }

    /// Every folder's display name with its ancestors prepended
    /// ("Parent – Child"). A cycle or a missing parent simply stops the walk.
    static func flattenedNames(_ folders: [EagleFolder]) -> [String: String] {
        var parentOf: [String: String] = [:]
        var nameOf: [String: String] = [:]
        for folder in folders {
            nameOf[folder.id] = folder.name
            for child in folder.childIDs { parentOf[child] = folder.id }
        }
        var out: [String: String] = [:]
        for folder in folders {
            var parts = [folder.name]
            var cursor = parentOf[folder.id]
            var guardCount = 0
            while let current = cursor, let name = nameOf[current], guardCount < 64 {
                parts.insert(name, at: 0)
                cursor = parentOf[current]
                guardCount += 1
            }
            out[folder.id] = parts.joined(separator: nestingSeparator)
        }
        return out
    }

    // MARK: - Folder tree

    private static func readFolders(at libraryURL: URL) -> [EagleFolder] {
        let url = libraryURL.appendingPathComponent("metadata.json")
        guard let data = BoundedRead.metadata(at: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["folders"] as? [[String: Any]] else { return [] }
        var out: [EagleFolder] = []
        walk(raw, into: &out)
        return out
    }

    private static func walk(_ nodes: [[String: Any]], into out: inout [EagleFolder]) {
        for node in nodes {
            guard let id = node["id"] as? String,
                  let name = (node["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty, !name.isEmpty else { continue }
            let children = (node["children"] as? [[String: Any]]) ?? []
            let childIDs = children.compactMap { $0["id"] as? String }
            out.append(EagleFolder(id: id, name: name, childIDs: childIDs))
            walk(children, into: &out)
        }
    }

    // MARK: - Items

    private static func readItems(at libraryURL: URL) -> [EagleItem] {
        let imagesURL = libraryURL.appendingPathComponent("images")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: imagesURL, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        return entries
            .filter { $0.pathExtension == "info" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { item(at: $0) }
    }

    /// nil for a corrupt/unreadable item — counted by the caller, never thrown.
    private static func item(at infoURL: URL) -> EagleItem? {
        let metaURL = infoURL.appendingPathComponent("metadata.json")
        guard let data = BoundedRead.metadata(at: metaURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = (dict["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return nil }
        // Eagle stores the id in the row, but the directory name is the
        // authority (that's the key the file itself is filed under).
        let id = (dict["id"] as? String)
            ?? (infoURL.deletingPathExtension().lastPathComponent)
        let ext = (dict["ext"] as? String) ?? ""
        let fileName = ext.isEmpty ? name : "\(name).\(ext)"
        let fileURL = infoURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        var out = EagleItem(id: id, fileURL: fileURL, name: fileName)
        out.tags = ((dict["tags"] as? [String]) ?? []).compactMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let star = (dict["star"] as? NSNumber)?.intValue, star > 0 { out.star = star }
        if let annotation = (dict["annotation"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !annotation.isEmpty {
            out.annotation = annotation
        }
        out.folderIDs = (dict["folders"] as? [String]) ?? []
        return out
    }
}
