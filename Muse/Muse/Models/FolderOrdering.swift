//
//  FolderOrdering.swift
//  Muse
//
//  Pure helper: order folder tiles before file tiles in the grid (Finder
//  pattern). The caller passes an already-sorted list (SmartSorter), so this
//  stable-partition keeps each group in the active sort order. A no-op when
//  there are no folders (e.g. the recursive view).
//

import Foundation

nonisolated enum FolderOrdering {
    static func foldersFirst(_ nodes: [FileNode]) -> [FileNode] {
        var folders: [FileNode] = []
        var files: [FileNode] = []
        folders.reserveCapacity(nodes.count)
        files.reserveCapacity(nodes.count)
        for n in nodes {
            if n.kind == .folder { folders.append(n) } else { files.append(n) }
        }
        return folders + files
    }
}
