//
//  BreadcrumbView.swift
//  Muse
//
//  Path breadcrumb for the toolbar — shows the active folder's path
//  relative to its root, with each segment clickable to navigate up.
//

import SwiftUI

struct BreadcrumbView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let folder = appState.selectedFolder {
            HStack(spacing: 4) {
                ForEach(Array(segments(for: folder).enumerated()), id: \.offset) { idx, segment in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(segment)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(idx == segments(for: folder).count - 1 ? .primary : .secondary)
                }
            }
        } else {
            EmptyView()
        }
    }

    private func segments(for folder: FolderNode) -> [String] {
        guard let rootURL = activeRootURL() else { return [folder.displayName] }
        let folderPath = folder.url.standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
        let rootName = appState.activeRoot?.displayName ?? rootURL.lastPathComponent
        if folderPath == rootPath { return [rootName] }
        // Trailing-slash guard: a sibling ("/a/Inspo Extra") must not read as under
        // the root ("/a/Inspo") and produce a corrupted breadcrumb slice.
        guard folderPath.hasPrefix(rootPath + "/") else { return [folder.displayName] }
        let rel = String(folderPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pieces = rel.split(separator: "/").map(String.init)
        return [rootName] + pieces
    }

    private func activeRootURL() -> URL? {
        guard let root = appState.activeRoot else { return nil }
        return appState.bookmarks.url(for: root)
    }
}
