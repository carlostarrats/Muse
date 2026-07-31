//
//  StackDisplay.swift
//  Muse
//
//  Pure collapse math (the Components/ convention). For each stack with ≥2
//  members present in `files`, keep the pick (if present) else the first in
//  the current order, and hide the rest — unless the stack is expanded.
//
//  "≥2 members PRESENT" matters: a stack whose other members live in another
//  folder must not collapse to a badge of 1.
//

import Foundation

nonisolated enum StackDisplay {
    struct Entry: Equatable {
        let stackID: String
        let isPick: Bool
    }

    struct Result: Equatable {
        var visible: [FileNode]
        /// Representative standardized path → member count IN VIEW.
        var badges: [String: Int]
        var hiddenPaths: Set<String>
    }

    static func collapse(_ files: [FileNode], entries: [String: Entry],
                         expanded: Set<String>) -> Result {
        guard !entries.isEmpty else {
            return Result(visible: files, badges: [:], hiddenPaths: [])
        }
        // Group present files by stack, preserving encounter order.
        var membersByStack: [String: [String]] = [:]
        var stackOrder: [String] = []
        for file in files {
            let path = file.url.standardizedFileURL.path
            guard let entry = entries[path] else { continue }
            if membersByStack[entry.stackID] == nil { stackOrder.append(entry.stackID) }
            membersByStack[entry.stackID, default: []].append(path)
        }

        var hidden: Set<String> = []
        var badges: [String: Int] = [:]
        for stackID in stackOrder {
            guard let memberPaths = membersByStack[stackID], memberPaths.count >= 2 else { continue }
            if expanded.contains(stackID) { continue }
            let chosen = memberPaths.first { entries[$0]?.isPick == true } ?? memberPaths[0]
            badges[chosen] = memberPaths.count
            for path in memberPaths where path != chosen { hidden.insert(path) }
        }

        let visible = hidden.isEmpty ? files
            : files.filter { !hidden.contains($0.url.standardizedFileURL.path) }
        return Result(visible: visible, badges: badges, hiddenPaths: hidden)
    }
}
