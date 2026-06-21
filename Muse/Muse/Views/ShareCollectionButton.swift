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
        .disabled(preparing || count == 0 || exportURLs.isEmpty)
        .help("Share collection")
        .accessibilityLabel("Share collection")
    }

    private func makePDF() async -> URL? {
        let urls = exportURLs
        let layoutAspect = appState.imageLayout.aspect
        let backdrop = appState.effectiveTileBackground
            .backdropRGB(for: appState.moodPalette)?.cgColor
        return await CollectionPDFExporter.makePDF(
            urls: urls, title: title, count: urls.count, columns: gridColumns,
            layoutAspect: layoutAspect, tileBackdrop: backdrop,
            tagLabels: appState.activeTagLabels)
    }

    private func save() async {
        preparing = true
        defer { preparing = false }
        guard let pdf = await makePDF() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = "\(title).pdf"
        panel.directoryURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        // Atomic overwrite — no pre-delete window that could destroy an
        // existing file if the write fails.
        if let data = try? Data(contentsOf: pdf) {
            try? data.write(to: dest, options: .atomic)
        }
    }

    private func share() async {
        preparing = true
        defer { preparing = false }
        guard let pdf = await makePDF() else { return }
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [pdf])
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }
}
