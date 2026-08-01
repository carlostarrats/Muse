//
//  LightroomPresetImportCard.swift
//  Muse
//
//  Progress for the Lightroom preset import. The picker already ran, so this
//  card starts working immediately.
//

import SwiftUI

struct LightroomPresetImportCard: View {
    let request: LightroomPresetImportRequest
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = LightroomPresetImportModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Lightroom Presets")
                .font(.title3.weight(.semibold))

            switch model.phase {
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
        .onAppear { model.start(urls: request.urls, appState: appState) }
        .onDisappear { model.cancel() }
    }
}
