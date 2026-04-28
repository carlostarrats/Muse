//
//  AppState.swift
//  Muse
//
//  Phase 0.5 — filesystem-native top-level state. Holds:
//  - Roots (user-selected folders, persisted via security-scoped bookmarks)
//  - Folder tree per active root
//  - Currently selected folder + its files
//  - Currently selected file (for preview)
//  - FSEvents watcher for live disk sync (Q3)
//  - Show-subfolders toggle (Q2 Adobe Bridge style)
//  - Show-hidden-files toggle (Q33)
//  - Water shader toggle (Q25)
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {

    // MARK: - Roots

    let bookmarks = BookmarkStore()

    /// Currently active root (the one whose tree is in the sidebar).
    @Published var activeRoot: Root?

    /// Root nodes for the sidebar tree, one per active root.
    @Published var rootNodes: [FolderNode] = []

    // MARK: - Active folder + grid contents

    @Published var selectedFolder: FolderNode?

    /// Files in the selected folder (or, if recursive, including subfolders).
    @Published var currentFiles: [FileNode] = []

    /// Currently selected file (drives preview/detail).
    @Published var selectedFile: FileNode?

    // MARK: - Modes

    /// Q2: include subfolders in the grid contents.
    @Published var showSubfolders: Bool = false

    /// Q33: show dotfiles / hidden files. Default off.
    @Published var showHidden: Bool = false

    // MARK: - Water shader

    @Published var fluidEnabled: Bool = false
    let fluidSim = FluidSim()
    @Published var fluidDispImage: Image = FluidSim.neutralImage
    private var fluidCancellable: AnyCancellable?

    // MARK: - Watcher

    private var watcher: FolderWatcher?
    private var bookmarksCancellable: AnyCancellable?

    init() {
        // Forward fluid sim displacement, throttled
        fluidCancellable = fluidSim.$dispImage
            .throttle(for: .milliseconds(33), scheduler: RunLoop.main, latest: true)
            .assign(to: \.fluidDispImage, on: self)

        rebuildRootNodes()
        bookmarksCancellable = bookmarks.$roots
            .sink { [weak self] _ in self?.rebuildRootNodes() }
    }

    // MARK: - Roots wiring

    private func rebuildRootNodes() {
        let nodes: [FolderNode] = bookmarks.roots.compactMap { root in
            guard let url = bookmarks.url(for: root) else { return nil }
            return FolderNode(url: url, displayName: root.displayName, isRoot: true)
        }
        rootNodes = nodes
        if activeRoot == nil, let first = bookmarks.roots.first {
            select(rootForFirstFolder: first)
        }
    }

    private func select(rootForFirstFolder root: Root) {
        activeRoot = root
        if let node = rootNodes.first(where: { $0.url == bookmarks.url(for: root) }) {
            select(folder: node)
        }
    }

    func pickAndAddRoot() {
        guard let root = bookmarks.pickAndAddRoot() else { return }
        rebuildRootNodes()
        if let node = rootNodes.first(where: { $0.url == bookmarks.url(for: root) }) {
            activeRoot = root
            select(folder: node)
        }
    }

    func removeRoot(_ root: Root) {
        bookmarks.removeRoot(root)
        if activeRoot?.id == root.id {
            activeRoot = bookmarks.roots.first
            selectedFolder = nil
            currentFiles = []
            selectedFile = nil
        }
        rebuildRootNodes()
    }

    // MARK: - Folder selection

    func select(folder: FolderNode) {
        selectedFolder = folder
        selectedFile = nil
        reloadCurrentFiles()
        startWatching(folder.url)
    }

    private func reloadCurrentFiles() {
        guard let folder = selectedFolder else {
            currentFiles = []
            return
        }
        if showSubfolders {
            currentFiles = recursiveFiles(at: folder.url)
        } else {
            currentFiles = FolderReader.files(in: folder.url, showHidden: showHidden)
        }
    }

    private func recursiveFiles(at url: URL) -> [FileNode] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isPackageKey, .fileSizeKey,
                .contentModificationDateKey, .creationDateKey
            ],
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else {
            return []
        }
        var nodes: [FileNode] = []
        for case let child as URL in enumerator {
            let v = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isDir = v?.isDirectory == true
            let isPackage = v?.isPackage == true
            if isDir && !isPackage { continue }
            nodes.append(FileNode(url: child))
        }
        return nodes.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    func toggleSubfolders() {
        showSubfolders.toggle()
        reloadCurrentFiles()
    }

    // MARK: - Watcher

    private func startWatching(_ url: URL) {
        if watcher == nil {
            watcher = FolderWatcher { [weak self] in
                self?.reloadCurrentFiles()
            }
        }
        watcher?.watch(url: url, recursive: showSubfolders)
    }
}
