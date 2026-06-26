//
//  ManageICloudSharesView.swift
//  Muse
//
//  "Manage iCloud Shares" — lists the iCloud collection shares Muse has made
//  and lets the user delete a folder to reclaim iCloud space. Styled to match
//  the ⓘ About modal (InfoSheet): same header/type sizes, SheetCloseButton,
//  and hairline dividers between rows only.
//

import SwiftUI

struct ManageICloudSharesView: View {
    @Environment(\.dismiss) private var dismiss
    private let store = ICloudShareStore.default
    @State private var records: [ICloudShareRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("iCloud Shares")
                    .font(.system(size: 24, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                SheetCloseButton { dismiss() }
            }
            .padding(.bottom, 20)

            if records.isEmpty {
                Text("No iCloud shares yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                            if index > 0 { rowDivider }
                            row(record)
                        }
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 600, height: 520)
        .onAppear { records = store.all() }
    }

    /// Hairline between rows (matches InfoSheet — between rows only, never
    /// under the header).
    private var rowDivider: some View {
        Divider().padding(.vertical, 16)
    }

    private func row(_ record: ICloudShareRecord) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(record.collectionName)
                    .font(.system(size: 15, weight: .semibold))
                Text("\(record.itemCount) images · \(record.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            DeleteShareButton { delete(record) }
        }
    }

    private func delete(_ record: ICloudShareRecord) {
        // Remove the folder Muse created in its own iCloud container; the OS
        // daemon propagates the removal. Then drop the record. The path comes
        // from the on-disk JSON store, so re-validate it the SAME way the copy
        // path does — a corrupted/unexpected stored path must never let
        // `removeItem` escape the share root (data-loss-sensitive container).
        let folder = URL(fileURLWithPath: record.folderPath)
        if let docs = ICloudZone.folderURL() {
            let shareRoot = ICloudSharePaths.shareRoot(zoneDocuments: docs)
            if ICloudSharePaths.isContainedShareFolder(folder, shareRoot: shareRoot) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        // Always drop the record (the user asked to remove it from the list);
        // if the zone was unresolvable or the path failed validation we simply
        // don't touch the filesystem.
        store.remove(id: record.id)
        records = store.all()
    }
}

/// Per-row delete affordance — a quiet text button that reddens on hover,
/// keeping the modal's restrained look (no heavy destructive bar).
private struct DeleteShareButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Delete")
                .font(.system(size: 13))
                .foregroundStyle(hovering ? Color.red : Color.secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Delete this iCloud share and free the space")
        .accessibilityLabel("Delete iCloud share")
    }
}
