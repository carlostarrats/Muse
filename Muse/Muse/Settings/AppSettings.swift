//
//  AppSettings.swift
//  Muse
//
//  User preferences for automatic organization. Both default ON. Turning one
//  off only affects folders processed AFTER the change — Muse stops auto-
//  tagging / auto-clustering newly indexed files. Nothing already tagged or
//  collected is removed or redone, and the manual paths still work (Analyze /
//  Regenerate Tags for tags; building your own collections by hand).
//
//  Read from non-UI code (AnalyzePipeline, CollectionsEngine) via these
//  accessors; the SettingsView binds @AppStorage to the same keys.
//

import Foundation

enum AppSettings {
    static let autoTagKey = "autoTagNewImages"
    static let autoCollectionsKey = "autoOrganizeCollections"

    /// Automatically run the Vision pass (tags/caption/colors/OCR) on newly
    /// indexed images. Default true. Unset → treated as on.
    static var autoTag: Bool {
        UserDefaults.standard.object(forKey: autoTagKey) as? Bool ?? true
    }

    /// Automatically cluster files into collections. Default true. Unset → on.
    static var autoCollections: Bool {
        UserDefaults.standard.object(forKey: autoCollectionsKey) as? Bool ?? true
    }
}
