//
//  EditVersionName.swift
//  Muse
//
//  Version names are mostly the user's own free text and are stored verbatim.
//  The ONE name Muse generates itself — the stack auto-preserved when you
//  switch away to another version — follows the app-wide rule instead:
//  canonical English in the database, localized at display time.
//
//  Storing the translation would put "Précédent" in a French user's library
//  forever, unreadable after a language switch and inconsistent with every
//  other Muse-derived label (Vision tags, intent names) which are all stored
//  canonical and localized on the way out.
//
//  Only the exact generated name is translated. A user who happens to type
//  "Previous" themselves gets the same word back, which is the right answer
//  either way; anything else passes through untouched, so real user names are
//  never mangled by a stray catalog hit.
//

import Foundation

enum EditVersionName {
    /// The name `EditStore.switchToVersion` gives the stack it auto-preserves.
    /// Canonical English — this is what lands in `edit_versions.name`.
    static let autoPreserved = "Previous"

    /// Display form: the generated name is localized, user names pass through.
    static func display(_ stored: String) -> String {
        stored == autoPreserved ? String(localized: "Previous") : stored
    }
}
