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
                    appState.fluidSim.start()
                    await appState.loadAll()
                }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
