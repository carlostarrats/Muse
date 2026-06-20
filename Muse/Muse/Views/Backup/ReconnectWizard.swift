//
//  ReconnectWizard.swift
//  Muse
//
//  Locked restore sheet: map each backed-up folder to its new location, then
//  Reconnect All. Matches InfoSheet chrome (600x720). No X — Cancel/Done only.
//

import SwiftUI
import AppKit

struct ReconnectWizard: View {
    @ObservedObject var model: ReconnectModel
    @Binding var isPresented: Bool
    let bookmarks: BookmarkStore

    @State private var confirmCancel = false

    private var anyLocated: Bool { model.folders.contains { $0.newLocation != nil } }
    private var collectionsDone: Int { model.collectionStatuses.filter { $0.reconnected > 0 }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Restore from Backup")
                .font(.system(size: 24, weight: .semibold))
                .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    pointAtParent
                    folderSection
                    collectionSection
                }
            }

            Spacer(minLength: 16)
            footer
        }
        .padding(28)
        .frame(width: 600, height: 720)
        .alert("Stop reconnecting?", isPresented: $confirmCancel) {
            Button("Keep Going", role: .cancel) {}
            Button("Stop", role: .destructive) { model.cancel(); isPresented = false }
        } message: {
            Text("Reconnection is in progress. Stopping leaves it partially done; you can restore again later.")
        }
    }

    private var pointAtParent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where are your files?").font(.system(size: 15, weight: .semibold))
            Text("Point at the folder that holds your copied library and Muse will line up your folders automatically. You can also locate any folder by hand below.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Point at folder…") {
                if let url = pickDirectory() { model.autoMap(parent: url) }
            }
            .disabled(model.isRunning)
        }
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Folders").font(.system(size: 15, weight: .semibold))
            ForEach(model.folders) { folder in
                HStack(spacing: 10) {
                    statusGlyph(folder.status)
                        .frame(width: 90, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.displayName).font(.system(size: 13, weight: .medium))
                        Text(folder.newLocation?.path ?? "Not located")
                            .font(.system(size: 11))
                            .foregroundStyle(folder.newLocation == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Locate…") {
                        if let url = pickDirectory() { model.setLocation(url, forFolder: folder.id) }
                    }
                    .disabled(model.isRunning)
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
    }

    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Collections").font(.system(size: 15, weight: .semibold))
            Text("\(collectionsDone) / \(model.collectionStatuses.count) re-established · \(model.overallPercent)% of images reconnected")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ForEach(model.collectionStatuses) { c in
                HStack {
                    Text(c.name).font(.system(size: 12))
                        .foregroundStyle(c.reconnected == 0 ? .secondary : .primary)
                    Spacer()
                    Text("\(c.reconnected)/\(c.total)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(c.reconnected == 0 ? .orange : .secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                if model.isRunning { confirmCancel = true } else { isPresented = false }
            }
            Spacer()
            if model.finished {
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Reconnect All") {
                    Task { await model.reconnectAll(bookmarks: bookmarks) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!anyLocated || model.isRunning)
            }
        }
    }

    @ViewBuilder
    private func statusGlyph(_ status: ReconnectModel.FolderStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "minus").foregroundStyle(.secondary)
        case .working:
            ProgressView().controlSize(.small)
        case .clean:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .flagged(let n):
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(n) not found").font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
    }

    private func pickDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
