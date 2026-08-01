//
//  TakeoutImportCard.swift
//  Muse
//
//  Options, then progress, for the Google Takeout import. Built only while
//  presented; `.onDisappear` cancels the run.
//

import SwiftUI

struct TakeoutImportCard: View {
    let request: TakeoutImportRequest
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = TakeoutImportModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from Google Takeout")
                .font(.title3.weight(.semibold))
            Text(request.folder.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            switch model.phase {
            case .options:
                Text("Muse reads these photos where they already are — nothing is copied or moved. It restores the dates, locations and descriptions Takeout left out of the image files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $model.favoritesAsTag) {
                    Text("Tag favorites as “Favorite”")
                }
                .toggleStyle(.checkbox)
                Picker(selection: $model.people) {
                    Text("Don't import").tag(TakeoutImportModel.PeopleChoice.skip)
                    Text("Add as tags").tag(TakeoutImportModel.PeopleChoice.tags)
                } label: {
                    Text("People named in Google Photos")
                }
                HStack {
                    Spacer()
                    ModalButton(title: String(localized: "Cancel"), isCancel: true) {
                        appState.importModal = nil
                    }
                    ModalButton(title: String(localized: "Import"),
                                kind: .prominent, isDefault: true) {
                        model.start(folder: request.folder, appState: appState)
                    }
                }
            case .running(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("Reading \(done) of \(total)…")
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
