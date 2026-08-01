//
//  ImportRunCard.swift
//  Muse
//
//  Progress for the metadata / Lightroom run. Built only while presented,
//  `.onAppear` starts the model, `.onDisappear` cancels it — the shipped
//  `MetadataImportSheet` contract, kept for every import source.
//
//  Dismissal cancels but never undoes: work already applied stays, and a
//  re-run finishes the rest and changes nothing already done.
//

import SwiftUI

struct ImportRunCard: View {
    let request: MetadataImportRequest
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = MetadataImportModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Metadata & Lightroom Edits")
                .font(.title3.weight(.semibold))
            Text(request.folder.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            switch model.phase {
            case .options:
                // Pre-scan only: flipping this mid-run would make the report
                // describe something that didn't happen.
                Toggle(isOn: $model.importLREdits) {
                    Text("Also import Lightroom adjustments (approximated)")
                }
                .toggleStyle(.checkbox)
                Text("Muse maps crop, white balance, exposure, contrast, vibrance, saturation and tone curves. Adaptive sliders like Highlights, Shadows and Clarity are listed in the report instead — they can't be translated honestly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                // The summary lives in ImportReportCard; the model swaps the
                // shell flag to `.report` on completion.
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .onDisappear { model.cancel() }
    }
}
