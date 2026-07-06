//
//  FileNameSplit.swift
//  Muse
//
//  Pure name logic for in-app file rename: split a filename into an editable
//  stem + a LOCKED extension (the last dot-suffix), recombine them, and validate
//  the shape of a proposed name. No filesystem, no DB — collision is checked at
//  the AppState layer. Mirrors FolderOps.sanitize as a tested pure seam.
//

import Foundation

enum RenameNameError: Error, Equatable { case empty, invalidCharacter, wouldHide }

enum FileNameSplit {

    /// Split `name` (a lastPathComponent) into (stem, ext) where `ext` is the
    /// last dot-suffix INCLUDING its dot, or "" when there is no extension.
    /// Multi-dot names use ONLY the last suffix (archive.tar.gz -> .gz). A
    /// leading-dot dotfile with no other dot (.gitignore) and a trailing-dot
    /// name (foo.) have no extension — the whole name is the stem.
    static func split(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: ".") else { return (name, "") }
        // Leading dot (index 0) => dotfile, no extension.
        if dot == name.startIndex { return (name, "") }
        let afterDot = name.index(after: dot)
        // Trailing dot => empty suffix, not an extension.
        if afterDot == name.endIndex { return (name, "") }
        return (String(name[name.startIndex..<dot]), String(name[dot..<name.endIndex]))
    }

    /// Re-append the locked extension to an edited stem. No trimming here.
    static func recombine(stem: String, ext: String) -> String { stem + ext }

    /// Validate the SHAPE of a proposed name (collision is checked elsewhere).
    /// Returns the final full name on success. `originalName` is the file's
    /// current basename, used to allow an already-hidden dotfile to keep its
    /// leading dot while forbidding a normal file from being hidden.
    static func validate(stem: String, ext: String,
                         originalName: String) -> Result<String, RenameNameError> {
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }
        let full = recombine(stem: trimmed, ext: ext)
        if full.contains("/") || full.contains(":") { return .failure(.invalidCharacter) }
        if full.hasPrefix(".") && !originalName.hasPrefix(".") { return .failure(.wouldHide) }
        return .success(full)
    }
}
