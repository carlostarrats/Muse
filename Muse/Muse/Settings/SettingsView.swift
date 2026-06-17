//
//  SettingsView.swift
//  Muse
//
//  Vestigial placeholder. No dedicated Preferences pane is planned —
//  settings live in the sidebar / toolbar / menus instead (roots, sort +
//  direction, show-subfolders, show-hidden, background mood). Kept only so
//  the Settings scene has something to render.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        VStack {
            Text("Settings")
                .font(.title2)
            Text("Coming in a later phase.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(width: 400, height: 200)
    }
}

#Preview {
    SettingsView()
}
