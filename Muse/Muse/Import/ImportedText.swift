//
//  ImportedText.swift
//  Muse
//
//  Title / caption / creator from another tool → one Muse NOTE.
//
//  Not `files.caption`: that column is Vision-owned and content-keyed, so a
//  human-written title has no business there. A note is per
//  (file_id, parent_dir), which is exactly the grain an imported per-file
//  string belongs to — and it is a field the user can edit afterwards, which
//  is the whole "always leave the user able to redo it their way" rule.
//

import Foundation

nonisolated enum ImportedText {
    static let maxLength = 2_000

    /// Ordered title · caption · "© creator", newline-joined, case-insensitively
    /// deduped (first spelling wins), whitespace-trimmed, length-capped.
    /// nil when nothing survives — an empty note is the absence of a note.
    static func note(title: String?, caption: String?, creator: String?) -> String? {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
            else { return nil }
            return t
        }
        var parts: [String] = []
        var seen = Set<String>()
        for value in [clean(title), clean(caption)] {
            guard let value else { continue }
            if seen.insert(value.lowercased()).inserted { parts.append(value) }
        }
        if let creator = clean(creator) {
            let line = "© " + creator
            if seen.insert(line.lowercased()).inserted { parts.append(line) }
        }
        guard !parts.isEmpty else { return nil }
        return String(parts.joined(separator: "\n").prefix(maxLength))
    }
}
