//
//  SidebarView.swift
//  Muse
//
//  Multi-root folder tree (Q1, Q26). Roots are listed as top-level
//  items; each is a lazy-loading hierarchical tree built with
//  OutlineGroup. Clicking a folder selects it as the active folder
//  (Q2 Adobe Bridge style).
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if appState.rootNodes.isEmpty && appState.stars.starred.isEmpty {
                emptyState
            } else {
                List(selection: Binding(
                    get: { appState.selectedFolder?.id },
                    set: { newID in
                        if let id = newID, let folder = findFolder(byID: id, in: appState.rootNodes) {
                            appState.select(folder: folder)
                        }
                    }
                )) {
                    if !appState.stars.starred.isEmpty {
                        Section("Starred") {
                            ForEach(appState.stars.starred) { star in
                                Button {
                                    appState.openStarred(star)
                                } label: {
                                    Label(star.displayName, systemImage: "star.fill")
                                        .foregroundStyle(.yellow, .primary)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Remove from Starred") {
                                        appState.stars.unstar(folder: URL(fileURLWithPath: star.path))
                                    }
                                }
                            }
                        }
                    }

                    Section("Folders") {
                        ForEach(appState.rootNodes) { root in
                            OutlineGroup(root, children: \.lazyChildren) { node in
                                FolderRowLabel(node: node, isRoot: node.id == root.id)
                                    .tag(node.id)
                                    .contextMenu {
                                        Button(appState.stars.isStarred(node.url) ? "Unstar" : "Star") {
                                            appState.toggleStar(folder: node)
                                        }
                                        if node.id == root.id {
                                            if let r = appState.bookmarks.roots.first(where: {
                                                appState.bookmarks.url(for: $0) == node.url
                                            }) {
                                                Divider()
                                                Button("Remove Folder") { appState.removeRoot(r) }
                                            }
                                        }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()
            HStack(spacing: 6) {
                Button {
                    appState.pickAndAddRoot()
                } label: {
                    Label("Add Folder", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 220)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No folders yet")
                .font(.callout)
            Text("Click \"Add Folder\" below to point Muse at a folder on your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }

    private func findFolder(byID id: UUID, in nodes: [FolderNode]) -> FolderNode? {
        for node in nodes {
            if node.id == id { return node }
            if let hit = findFolder(byID: id, in: node.children) {
                return hit
            }
        }
        return nil
    }
}

private struct FolderRowLabel: View {
    @ObservedObject var node: FolderNode
    let isRoot: Bool

    var body: some View {
        Label(node.displayName, systemImage: isRoot ? "externaldrive" : "folder")
            .font(.system(size: 13, weight: isRoot ? .medium : .regular))
            .lineLimit(1)
            .onAppear { node.loadChildrenIfNeeded() }
    }
}

// MARK: - OutlineGroup support

extension FolderNode {
    /// OutlineGroup uses this to discover children. Returns nil for leaf-like
    /// nodes (no children loaded yet AND we haven't tried to load) so the
    /// disclosure indicator shows; once loaded with zero children, returns
    /// nil so the indicator hides.
    var lazyChildren: [FolderNode]? {
        if !isLoaded {
            // Eagerly load on first access. Acceptable: only fires when the row
            // actually becomes visible.
            loadChildrenIfNeeded()
        }
        return children.isEmpty ? nil : children
    }
}
