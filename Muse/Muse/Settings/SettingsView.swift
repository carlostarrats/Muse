//
//  SettingsView.swift
//  Muse
//
//  Phase 0 placeholder. Phase 6 builds out the real preferences pane:
//  roots management, sort/view defaults, AI master kill, dedup
//  thresholds, thumbnail cache size, hidden-files toggle.
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
