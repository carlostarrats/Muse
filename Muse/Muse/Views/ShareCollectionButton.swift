//
//  ShareCollectionButton.swift
//  Muse
//
//  In-collection header control: a menu with "Save to…" (NSSavePanel with a
//  Paper Size dropdown, defaulted to Desktop, builds a paginated PDF of the
//  collection's displayed images) and "Share Drive Link" (Google Drive
//  publish). No generic system share sheet — "Share Drive Link" is the only
//  share path, to avoid offering two confusingly similar share actions.
//

import SwiftUI

struct ShareCollectionButton: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject private var googleAuth: GoogleOAuth
    let title: String
    let count: Int

    // Mirror the grid's current density (the bottom-right column slider).
    @AppStorage("gridColumnCount") private var gridColumns = 4
    @State private var hovering = false
    @State private var preparing = false
    @State private var showingDriveShare = false
    @State private var exportFailed = false

    /// The collection's CURRENTLY VISIBLE members, in grid order — the on-screen
    /// set, so an active tag/facet filter narrows the export (images and file
    /// cards alike; folders are excluded — they aren't grid content to export).
    private var exportURLs: [URL] {
        appState.visibleFiles.compactMap { node in
            node.kind == .folder ? nil : node.url
        }
    }

    var body: some View {
        Menu {
            Button("Save to…") { Task { await save() } }
            Button("Share Drive Link") { showingDriveShare = true }
        } label: {
            Group {
                if preparing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(hovering ? .primary : .secondary)
                }
            }
            .frame(width: 40, height: 40)
            .background(Circle().fill(.primary.opacity(hovering ? 0.16 : 0.08)))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .disabled(preparing || count == 0 || exportURLs.isEmpty)
        .help("Share collection")
        .accessibilityLabel("Share collection")
        .sheet(isPresented: $showingDriveShare) {
            DriveShareSheet(auth: googleAuth, title: title, urls: exportURLs) {
                showingDriveShare = false
            }
        }
        .alert("Couldn’t Export the PDF", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The PDF couldn’t be prepared — some images may be unreadable — or the location couldn’t be written. Check the images and that the location is writable with enough free space.")
        }
    }

    private func save() async {
        preparing = true
        defer { preparing = false }
        let outcome = await CollectionPDFSave.run(
            title: title, urls: exportURLs, appState: appState, gridColumns: gridColumns,
            tagLabels: appState.activeTagLabels)
        // A failure (every image undecodable/vanished, or a failed write) is a
        // silent no-op otherwise — the panel closes looking like success. Surface
        // it: a save the user just triggered warrants a confirming alert (the
        // macOS norm), not a transient toast. A user cancel is not a failure.
        if outcome == .failed { exportFailed = true }
    }
}
