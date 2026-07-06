//
//  ICloudSidebarVisibility.swift
//  Muse
//
//  Pure decision logic for whether the app-managed iCloud "Muse" root shows
//  in the sidebar, and whether the Settings toggle that governs it is enabled.
//  The single source of truth shared by SidebarView (render gate) and
//  SettingsView (toggle disabled + footer note) so the two can't disagree.
//
//  The user may hide the iCloud row ONLY when the folder is empty. A folder
//  with files always shows (toggle disabled); an un-computed count is treated
//  as visible so the row never flickers out during the launch window before
//  folderStats populates.
//

import Foundation

enum ICloudSidebarVisibility {
    /// The iCloud folder's content state, derived from its recursive file count.
    enum Presence: Equatable {
        case notConfigured  // no iCloud URL (Debug build / signed out / unavailable)
        case empty          // configured, recursive file count == 0
        case hasFiles       // configured, recursive file count > 0
        case unknown        // configured, count not computed yet (nil)
    }

    /// - Parameters:
    ///   - configured: whether an iCloud folder URL exists.
    ///   - recursiveFileCount: the folder's recursive file count, or nil if not
    ///     yet computed.
    static func presence(configured: Bool, recursiveFileCount: Int?) -> Presence {
        guard configured else { return .notConfigured }
        guard let count = recursiveFileCount else { return .unknown }
        return count == 0 ? .empty : .hasFiles
    }

    /// Should the iCloud row render in the sidebar?
    static func rowVisible(_ p: Presence, showSetting: Bool) -> Bool {
        switch p {
        case .notConfigured: return false      // nothing to show
        case .hasFiles, .unknown: return true  // always show; unknown avoids flicker
        case .empty: return showSetting        // the one case the user controls
        }
    }

    /// Is the Settings toggle disabled (greyed) because the folder can't be hidden?
    static func toggleDisabled(_ p: Presence) -> Bool {
        if case .hasFiles = p { return true }
        return false
    }
}
