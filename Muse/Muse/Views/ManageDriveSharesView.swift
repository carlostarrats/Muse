//
//  ManageDriveSharesView.swift
//  Muse
//
//  "Manage Drive Shares" (View menu) — lists live Drive shares Muse has made;
//  open the page link, or Delete now (unpublish = delete the Drive folder
//  immediately). Styled like the ⓘ About modal (InfoSheet).
//

import SwiftUI
import AppKit

struct ManageDriveSharesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var googleAuth: GoogleOAuth
    private let store = DriveShareStore.default
    @State private var records: [DriveShareRecord] = []
    @State private var deleting: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Drive Shares").font(.system(size: 24, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                SheetCloseButton { dismiss() }
            }
            .padding(.bottom, 20)

            if records.isEmpty {
                Text("No Drive shares yet.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                            if index > 0 { Divider().padding(.vertical, 16) }
                            row(record)
                        }
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 520, height: 380)
        .onAppear { records = store.all() }
    }

    private func row(_ record: DriveShareRecord) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.collectionName).font(.system(size: 15, weight: .semibold))
                Text("\(record.itemCount) images · expires \(record.expiry.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Link") {
                if let url = URL(string: record.pageURL) { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.link)
            if deleting.contains(record.id) {
                ProgressView().controlSize(.small)
            } else {
                Button(role: .destructive) { Task { await delete(record) } } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Unpublish — delete this share's Drive folder now")
                .accessibilityLabel("Unpublish Drive share")
            }
        }
    }

    private func delete(_ record: DriveShareRecord) async {
        deleting.insert(record.id)
        defer { deleting.remove(record.id) }
        let client = DriveClient(auth: googleAuth)
        try? await client.deleteFolder(id: record.folderID)
        store.remove(id: record.id)
        records = store.all()
    }
}
