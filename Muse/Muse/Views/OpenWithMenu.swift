//
//  OpenWithMenu.swift
//  Muse
//
//  Right-click "Open With…" submenu listing every macOS app registered
//  for a file's UTI via LaunchServices. Adds explicit Reveal in Finder
//  and Open in Default at the top.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct OpenWithMenu: View {
    let url: URL

    @State private var apps: [URL] = []

    var body: some View {
        Group {
            Button("Open") {
                NSWorkspace.shared.open(url)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            if !apps.isEmpty {
                Menu("Open With") {
                    ForEach(apps, id: \.self) { appURL in
                        Button(appURL.deletingPathExtension().lastPathComponent) {
                            openWith(appURL: appURL)
                        }
                    }
                }
            }
        }
        .task(id: url) {
            apps = Self.applications(for: url)
        }
    }

    private func openWith(appURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, _ in }
    }

    static func applications(for url: URL) -> [URL] {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                ?? UTType(filenameExtension: url.pathExtension) else { return [] }
        let candidates = NSWorkspace.shared.urlsForApplications(toOpen: type)
        // Sort alphabetically by app name
        return candidates.sorted { lhs, rhs in
            lhs.deletingPathExtension().lastPathComponent
                .localizedCaseInsensitiveCompare(rhs.deletingPathExtension().lastPathComponent) == .orderedAscending
        }
    }
}
