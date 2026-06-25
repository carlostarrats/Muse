//
//  ManageICloudSharesView.swift
//  Muse
//
//  File-menu "Manage iCloud Shares…" — lists the iCloud collection shares Muse
//  has made and lets the user delete a folder to reclaim iCloud space. The only
//  surface for this list (no in-app navigation entry, by design).
//

import SwiftUI

struct ManageICloudSharesView: View {
    @Environment(\.dismiss) private var dismiss
    private let store = ICloudShareStore.default
    @State private var records: [ICloudShareRecord] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("iCloud Shares").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if records.isEmpty {
                Spacer()
                Text("No iCloud shares yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(records) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.collectionName)
                                Text("\(record.itemCount) images · \(record.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { delete(record) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete this iCloud share and free the space")
                            .accessibilityLabel("Delete iCloud share")
                        }
                    }
                }
            }
        }
        .frame(width: 460, height: 360)
        .onAppear { records = store.all() }
    }

    private func delete(_ record: ICloudShareRecord) {
        // Remove the folder Muse created in its own iCloud container; the OS
        // daemon propagates the removal. Then drop the record.
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: record.folderPath))
        store.remove(id: record.id)
        records = store.all()
    }
}
