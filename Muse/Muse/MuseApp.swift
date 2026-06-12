//
//  MuseApp.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI

@main
struct MuseApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    // fluidSim starts on demand via AppState.fluidEnabled —
                    // a 60fps CPU timer must not run while the effect is off.
                    ThumbnailCache.shared.enforceDiskCap()
                }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
