//
//  EditCopyNaming.swift
//  Muse
//
//  Filenames for Edit-a-Copy. `<stem>-Edit.<ext>`, then `-Edit-2`, `-Edit-3`…
//
//  The ladder is CASE-INSENSITIVE because macOS volumes usually are: matching
//  case-sensitively would hand back a name that then collides on disk, and the
//  copy would either fail or overwrite.
//

import Foundation

nonisolated enum EditCopyNaming {
    static let suffix = "Edit"

    static func candidate(stem: String, ext: String, existing: Set<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        var name = "\(stem)-\(suffix).\(ext)"
        if !taken.contains(name.lowercased()) { return name }
        var n = 2
        repeat {
            name = "\(stem)-\(suffix)-\(n).\(ext)"
            n += 1
        } while taken.contains(name.lowercased())
        return name
    }

    /// RAW/DNG copies render 16-bit TIFF — an editing master. External editors
    /// can't write RAW back, so handing one a `.cr3` produces a file the user
    /// can open and never save. Everything else keeps its container.
    static func targetExtension(for url: URL, isRaw: Bool) -> String {
        isRaw ? "tif" : url.pathExtension.lowercased()
    }
}
