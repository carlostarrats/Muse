//
//  EagleImportCard.swift
//  Muse
//
//  Confirmation, then progress, for the Eagle library import.
//

import SwiftUI

struct EagleImportCard: View {
    let request: EagleImportRequest
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = EagleImportModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from Eagle")
                .font(.title3.weight(.semibold))
            Text(request.libraryURL.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            switch model.phase {
            case .options:
                Text("Muse copies the images into \(request.destination.lastPathComponent). Your Eagle library is only read — it is never changed or moved. Tags, stars, annotations and folders come across; saved links, smart folders and palettes don't.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    ModalButton(title: String(localized: "Cancel"), isCancel: true) {
                        appState.importModal = nil
                    }
                    ModalButton(title: String(localized: "Import"),
                                kind: .prominent, isDefault: true) {
                        model.start(request: request, appState: appState)
                    }
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
