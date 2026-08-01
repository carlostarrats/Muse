//
//  ApplePhotosImportCard.swift
//  Muse
//
//  Options, authorization, then progress for the Apple Photos import.
//

import SwiftUI

struct ApplePhotosImportCard: View {
    let request: ApplePhotosImportRequest
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = ApplePhotosImportModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from Apple Photos")
                .font(.title3.weight(.semibold))
            Text(request.destination.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            switch model.phase {
            case .options:
                Text("Muse copies each photo as it looks now into the folder you chose. Edits made in Photos are already part of that picture, but the individual adjustments can't be recovered — Apple keeps them in a private format.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $model.recreateAlbums) {
                    Text("Recreate albums as collections")
                }
                .toggleStyle(.checkbox)
                Toggle(isOn: $model.favoritesAsTag) {
                    Text("Tag favorites as “Favorite”")
                }
                .toggleStyle(.checkbox)
                HStack {
                    Spacer()
                    ModalButton(title: String(localized: "Cancel"), isCancel: true) {
                        appState.importModal = nil
                    }
                    ModalButton(title: String(localized: "Import"),
                                kind: .prominent, isDefault: true) {
                        model.start(destination: request.destination, appState: appState)
                    }
                }
            case .requestingAccess:
                ProgressView()
                Text("Waiting for permission to read your Photos library…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .denied:
                Text("Muse doesn't have permission to read your Photos library. You can grant it in System Settings › Privacy & Security › Photos.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    ModalButton(title: String(localized: "Done"), kind: .prominent,
                                isDefault: true) { appState.importModal = nil }
                }
            case .running(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("Copying \(done) of \(total)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                HStack {
                    Spacer()
                    ModalButton(title: String(localized: "Cancel"), isCancel: true) {
                        appState.importModal = nil
                    }
                }
            case .done:
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .onDisappear { model.cancel() }
    }
}
