//
//  MetadataImportSheet.swift
//  Muse
//
//  Progress + summary for File > Import Keywords & Ratings…. Content-sized
//  (width-only frame — never a fixed height, per the sheet rule). Dismissal
//  cancels the run (like the Drive share sheet): work already applied stays
//  and a re-run is idempotent.
//

import SwiftUI

struct MetadataImportSheet: View {
    let request: MetadataImportRequest
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = MetadataImportModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Keywords & Ratings")
                .font(.title3.weight(.semibold))
            Text(request.folder.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            switch model.phase {
            case .running(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("Reading \(done) of \(total)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            case .done(let imported, let none, let skipped):
                Text("Imported keywords or ratings for \(imported) files.")
                    .font(.callout)
                if none > 0 {
                    Text("\(none) had none to import.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if skipped > 0 {
                    Text("\(skipped) skipped (unreadable or not downloaded).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear { model.start(folder: request.folder, appState: appState) }
        .onDisappear { model.cancel() }
    }

    private func dismiss() {
        appState.metadataImportRequest = nil
    }
}
