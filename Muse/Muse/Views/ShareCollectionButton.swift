//
//  ShareCollectionButton.swift
//  Muse
//
//  In-collection header control: a menu with "Save to…" (NSSavePanel,
//  defaulted to Desktop) and "Share" (standard NSSharingServicePicker). Both
//  build a paginated PDF of the collection's displayed images first. Nothing
//  about the system share sheet is customized; no new entitlement is needed.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ShareCollectionButton: View {
    @EnvironmentObject var appState: AppState
    let title: String
    let count: Int

    // Mirror the grid's current density (the bottom-right column slider).
    @AppStorage("gridColumnCount") private var gridColumns = 4
    @State private var hovering = false
    @State private var preparing = false

    /// The collection's displayed image members, in grid order.
    private var imageURLs: [URL] {
        (appState.activeCollectionFiles ?? []).compactMap { node in
            switch node.kind {
            case .image, .raw, .psd: return node.url
            default: return nil
            }
        }
    }

    var body: some View {
        Menu {
            Button("Save to…") { Task { await save() } }
            Button("Share") { Task { await share() } }
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
        .disabled(preparing || count == 0 || imageURLs.isEmpty)
        .help("Share collection")
    }

    private func buildPDF() async -> URL? {
        preparing = true
        defer { preparing = false }
        let urls = imageURLs
        return await CollectionPDFExporter.makePDF(
            urls: urls, title: title, count: urls.count, columns: gridColumns)
    }

    private func save() async {
        guard let pdf = await buildPDF() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = "\(title).pdf"
        panel.directoryURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: pdf, to: dest)
    }

    private func share() async {
        guard let pdf = await buildPDF() else { return }
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [pdf])
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }
}
