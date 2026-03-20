//
//  ViewSwitcher.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI

/// Toolbar segmented control for switching between Grid, Universe, and Folder views.
struct ViewSwitcher: View {
    @EnvironmentObject var appState: AppState

    private var currentMode: String {
        switch appState.viewMode {
        case .grid: return "grid"
        case .universe, .globe: return "universe"
        case .folder: return "folder"
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            viewButton(icon: "square.grid.2x2", mode: "grid") {
                appState.viewMode = .grid
            }
            viewButton(icon: "globe", mode: "universe") {
                appState.viewMode = .universe
            }
            viewButton(icon: "folder", mode: "folder") {
                appState.viewMode = .folder
            }
        }
        .padding(2)
        .background(Color.gray.opacity(0.15))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func viewButton(icon: String, mode: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
                .background(
                    currentMode == mode
                    ? Color.accentColor.opacity(0.25)
                    : Color.clear
                )
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}
