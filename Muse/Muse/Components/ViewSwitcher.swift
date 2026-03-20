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
        .padding(4)
    }

    @ViewBuilder
    private func viewButton(icon: String, mode: String, action: @escaping () -> Void) -> some View {
        let isActive = currentMode == mode
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 22)
                .background(
                    isActive
                    ? RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                    : nil
                )
        }
        .buttonStyle(.plain)
    }
}
