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
        .onAppear {
            records = store.all()      // show what we have immediately…
            Task { await pruneMissing() } // …then drop any whose Drive folder is gone.
        }
    }

    /// Remove rows whose Drive folder no longer exists — the user deleted/trashed
    /// it in Google Drive directly, or it belongs to a since-switched account
    /// (drive.file can't see it → 404). Network happens only here, inside this
    /// explicit "Manage" action. Conservative: prune ONLY on a definitive
    /// not-found; any thrown error (offline / auth / 5xx) is inconclusive and the
    /// record is kept, and nothing is pruned while signed out.
    private func pruneMissing() async {
        guard googleAuth.isSignedIn else { return }
        let client = DriveClient(auth: googleAuth)
        var goneIDs: [String] = []
        for record in store.all() {
            if let exists = try? await client.folderExists(id: record.folderID), exists == false {
                goneIDs.append(record.id)
            }
        }
        guard goneIDs.isEmpty == false else { return }
        for id in goneIDs { store.remove(id: id) }
        records = store.all()
    }

    private func row(_ record: DriveShareRecord) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.collectionName).font(.system(size: 15, weight: .semibold))
                Text("\(record.itemCount) images · expires \(record.expiry.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            OpenLinkButton {
                if let url = URL(string: record.pageURL) { NSWorkspace.shared.open(url) }
            }
            if deleting.contains(record.id) {
                ProgressView().controlSize(.small).frame(width: 18)
            } else {
                TrashButton { Task { await delete(record) } }
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

/// "Open Link" — accent text that underlines + brightens on hover.
private struct OpenLinkButton: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text("Open Link")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor.opacity(hovering ? 1 : 0.85))
                .underline(hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Trash — secondary glyph that reddens on hover.
private struct TrashButton: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .foregroundStyle(hovering ? Color.red : Color.secondary)
                .frame(width: 18)
        }
        .buttonStyle(.plain)
        .help("Unpublish — delete this share's Drive folder now")
        .accessibilityLabel("Unpublish Drive share")
        .onHover { hovering = $0 }
    }
}
