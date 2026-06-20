//
//  ReconnectWizard.swift
//  Muse
//
//  Locked restore sheet. The backup is already loaded (picked from the menu);
//  here the user locates each backed-up folder ONE AT A TIME — folders can live
//  anywhere — and locating reconnects that folder immediately. No master
//  "do it all" action. Matches InfoSheet chrome (600x720). No X — Done only.
//

import SwiftUI
import AppKit

struct ReconnectWizard: View {
    @ObservedObject var model: ReconnectModel
    @Binding var isPresented: Bool
    let bookmarks: BookmarkStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Restore from Backup")
                .font(.system(size: 24, weight: .semibold))
            Text("Reconnect your folders and collections. Locate each folder where it lives now — they can be anywhere.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    folderSection
                    collectionCard
                }
            }

            Spacer(minLength: 16)
            footer
        }
        .padding(28)
        .frame(width: 600, height: 720)
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Folders").font(.system(size: 15, weight: .semibold))
            ForEach(model.folders) { folder in
                HStack(spacing: 10) {
                    statusGlyph(folder.status)
                        .frame(width: 128, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.displayName).font(.system(size: 13, weight: .medium))
                        Text(folder.newLocation?.path ?? "Not located")
                            .font(.system(size: 11))
                            .foregroundStyle(folder.newLocation == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(folder.newLocation == nil ? "Locate…" : "Relocate…") {
                        if let url = pickDirectory() {
                            Task { await model.reconnectFolder(id: folder.id, location: url,
                                                               bookmarks: bookmarks) }
                        }
                    }
                    .disabled(folder.status == .working)
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
    }

    private var collectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Collections").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(model.collectionsDone) / \(model.collectionStatuses.count) re-established · \(model.overallPercent)%")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { isPresented = false }
                .keyboardShortcut(.defaultAction)
                .disabled(model.folders.contains { $0.status == .working })
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
        case .flagged(let unmatched, let nameOnly):
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(flaggedText(unmatched: unmatched, nameOnly: nameOnly))
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .lineLimit(1)
            }
        case .failed:
            HStack(spacing: 3) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text("couldn't save").font(.system(size: 10)).foregroundStyle(.red)
            }
        }
    }

    private func flaggedText(unmatched: Int, nameOnly: Int) -> String {
        switch (unmatched, nameOnly) {
        case let (u, 0):        return "\(u) not found"
        case let (0, n):        return "\(n) by name — check"
        case let (u, n):        return "\(u) not found · \(n) by name"
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
