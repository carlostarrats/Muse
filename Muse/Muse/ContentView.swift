//
//  ContentView.swift
//  Muse
//
//  Phase 0.5 main shell: NavigationSplitView with the sidebar +
//  breadcrumb toolbar + grid. Selected file pops up the viewer overlay
//  via ViewerRouter.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            ZStack {
                GridView()

                if let selected = appState.selectedFile {
                    ViewerRouter(file: selected)
                        .transition(.opacity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    BreadcrumbView()
                }

                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $appState.showSubfolders) {
                        Image(systemName: "rectangle.stack")
                    }
                    .help(appState.showSubfolders
                          ? "Hide files inside subfolders"
                          : "Show files inside subfolders")
                    .onChange(of: appState.showSubfolders) { _, _ in
                        appState.toggleSubfolders()
                    }
                }

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
            .animation(.easeInOut(duration: 0.18), value: appState.selectedFile?.id)
        }
        .background(
            Button(action: {
                if appState.selectedFile != nil { appState.selectedFile = nil }
            }) {
                EmptyView()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .hidden()
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
