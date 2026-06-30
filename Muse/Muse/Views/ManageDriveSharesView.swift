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

/// Which date the Manage list sorts on, and in which direction. Persisted so
/// the choice sticks between openings.
enum DriveShareSortKey: String { case expires, created }
enum DriveShareSortOrder: String { case soonest, latest }

struct ManageDriveSharesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var googleAuth: GoogleOAuth
    private let store = DriveShareStore.default
    @State private var records: [DriveShareRecord] = []
    @State private var deleting: Set<String> = []
    @State private var didPrune = false
    @State private var unpublishFailed = false
    // Always open on "Expires · Earliest" so the soonest-to-expire shares are at
    // the top every time (not persisted — resets on each open).
    @State private var sortKey: DriveShareSortKey = .expires
    @State private var sortOrder: DriveShareSortOrder = .soonest

    /// Records ordered by the chosen key/direction. "Soonest" = earliest date
    /// first (ascending); "Latest" = newest first (descending).
    private var sortedRecords: [DriveShareRecord] {
        records.sorted { a, b in
            let da = sortKey == .expires ? a.expiry : a.createdAt
            let db = sortKey == .expires ? b.expiry : b.createdAt
            return sortOrder == .soonest ? da < db : da > db
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Manage Drive Shares").font(.system(size: 24, weight: .semibold))
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
                sortControls
                    .padding(.bottom, 16)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sortedRecords.enumerated()), id: \.element.id) { index, record in
                            if index > 0 { Divider().padding(.vertical, 16) }
                            row(record)
                        }
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 600, height: 400)
        .alert("Couldn’t Unpublish", isPresented: $unpublishFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The Drive folder couldn’t be deleted — you may be offline or signed out. The share is still live; try again, or remove it from Google Drive directly.")
        }
        .onAppear {
            records = store.all()      // show what we have immediately…
            guard didPrune == false else { return }
            didPrune = true
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
        store.remove(ids: goneIDs)   // single rewrite, not one per id
        records = store.all()
    }

    private var sortControls: some View {
        HStack(spacing: 8) {
            Text("Sort by").font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("", selection: $sortKey) {
                Text("Expires").tag(DriveShareSortKey.expires)
                Text("Created").tag(DriveShareSortKey.created)
            }
            .labelsHidden().fixedSize()
            .accessibilityLabel(Text("Sort by"))
            Picker("", selection: $sortOrder) {
                // "Earliest/Latest" reads naturally for both a creation date and
                // an expiry date. Earliest = ascending, Latest = descending.
                Text("Earliest").tag(DriveShareSortOrder.soonest)
                Text("Latest").tag(DriveShareSortOrder.latest)
            }
            .labelsHidden().fixedSize()
            .accessibilityLabel(Text("Sort order"))
            Spacer()
        }
    }

    /// Thin column separator between the metadata fields.
    private var metaPipe: some View {
        Text(verbatim: "|").foregroundStyle(.tertiary).padding(.horizontal, 8)
    }

    private func row(_ record: DriveShareRecord) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.collectionName).font(.system(size: 15, weight: .semibold))
                // Pipe-separated metadata, flowing naturally (no fixed columns).
                HStack(spacing: 0) {
                    Text("\(record.itemCount) images")
                    metaPipe
                    Text("created \(record.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    metaPipe
                    Text("expires \(record.expiry.formatted(date: .abbreviated, time: .omitted))")
                }
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
        // Drop the local record ONLY if the folder is definitively gone.
        // `deleteFolder` treats 404 as success (already gone), so a genuinely
        // missing folder still clears the row; but a real failure (offline / 5xx
        // / auth / token-refresh throw) must KEEP the record — the share folder
        // is public (anyone-reader) and a forgotten record can never be retried
        // or swept, leaving an orphaned live link.
        do { try await client.deleteFolder(id: record.folderID) }
        catch {
            // Keep the record (the public folder may still be live), but tell the
            // user — a silent return looks like the trash button did nothing.
            unpublishFailed = true
            return
        }
        store.remove(id: record.id)
        records = store.all()
    }
}

/// "Open Link" — a bordered button (accent label), filled on hover.
private struct OpenLinkButton: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text("Open Link")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(hovering ? 0.18 : 0.10)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.accentColor.opacity(0.30)))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Trash — a bordered icon button that reddens + fills on hover.
private struct TrashButton: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 13))
                .foregroundStyle(hovering ? Color.red : Color.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(hovering ? Color.red.opacity(0.12) : Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(hovering ? Color.red.opacity(0.35) : Color.primary.opacity(0.15)))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("Unpublish — delete this share's Drive folder now")
        .accessibilityLabel("Unpublish Drive share")
        .onHover { hovering = $0 }
    }
}
