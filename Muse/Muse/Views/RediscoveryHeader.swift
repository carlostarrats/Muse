//
//  RediscoveryHeader.swift
//  Muse
//
//  Mounted exactly where CollectionsRow mounts, and with the same metrics as
//  ActiveCollectionHeader: back arrow, 42pt title, count. Shuffle adds a
//  "Shuffle Again" button (the only surface that re-samples on demand).
//

import SwiftUI

struct RediscoveryHeader: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store = RediscoveryStore.shared

    var body: some View {
        if let surface = store.active {
            HStack(spacing: 18) {
                BackArrowButton(help: String(localized: "Back")) {
                    appState.closeRediscovery()
                }
                Text(surface.title)
                    .font(.system(size: 42, weight: .semibold))
                Text("\(store.files?.count ?? 0)")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if surface == .shuffle {
                    ModalButton(title: String(localized: "Shuffle Again"),
                                kind: .normal) {
                        store.reshuffle(roots: appState.rootPathList)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 48)
            .transition(.opacity)
        }
    }
}
