//
//  SettingsView.swift
//  Muse
//
//  The Preferences window (app menu → Settings…, ⌘,). Holds the automatic-
//  organization opt-outs. Both default ON; turning one off only affects
//  folders processed afterward — nothing already done is removed or redone,
//  and the manual paths (Analyze / Regenerate Tags, hand-made collections)
//  keep working. The accessors live in AppSettings (read by the pipeline).
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.autoTagKey) private var autoTag = true
    @AppStorage(AppSettings.autoCollectionsKey) private var autoCollections = true
    @AppStorage(AppSettings.showFileNamesKey) private var showFileNames = false
    @AppStorage(AppSettings.showCollectionsInSidebarKey) private var showCollectionsInSidebar = false

    var body: some View {
        Form {
            Section {
                Toggle("Automatically tag new images", isOn: $autoTag)
                Toggle("Automatically organize into collections", isOn: $autoCollections)
            } header: {
                Text("Automatic organization")
            } footer: {
                Text("Applies to folders added from now on. Tags and collections "
                     + "you already have are kept. You can still analyze a folder "
                     + "or build your own collections by hand at any time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show file names", isOn: $showFileNames)
            } header: {
                Text("Grid")
            } footer: {
                Text("Show each file's name beneath its thumbnail in the grid.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show Collections in the Sidebar", isOn: $showCollectionsInSidebar)
            } header: {
                Text("Sidebar")
            } footer: {
                Text("Show your collections as a collapsible section beneath the "
                     + "folders, with their own sort order.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    SettingsView()
}
