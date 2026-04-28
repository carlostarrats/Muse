//
//  ContentView.swift
//  Muse
//
//  Phase 0 placeholder shell. Will be replaced in Phase 0.5 by the
//  sidebar (folder tree) + grid + breadcrumb layout.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "folder.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("Muse — Phase 0")
                .font(.title)
                .fontWeight(.semibold)

            Text("Filesystem-native rewrite in progress.\nPhase 0.5 will land the sidebar + grid.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(minWidth: 600, minHeight: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.fluidEnabled.toggle()
                } label: {
                    Image(systemName: "drop.fill")
                        .foregroundStyle(appState.fluidEnabled ? Color.blue : Color.primary)
                }
                .help(appState.fluidEnabled ? "Disable Water Effect" : "Enable Water Effect")
            }
        }
        .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
