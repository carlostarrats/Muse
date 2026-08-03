//
//  OpenWithMenu.swift
//  Muse
//
//  Right-click "Open With…" menu listing every macOS app registered for a
//  file's UTI via LaunchServices, with each app's real icon, the default
//  marked, and an "Other…" picker — matching Finder's Open With submenu.
//  Apps are computed synchronously (a context-menu `.task` doesn't fire
//  reliably, which used to leave the submenu empty). Adds explicit Open and
//  Reveal in Finder at the top.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct OpenWithMenu: View {
    let url: URL
    @EnvironmentObject private var appState: AppState

    var body: some View {
        // Every external hand-off routes through the fork check — a file with
        // Muse edits opened externally would otherwise silently be the
        // unedited original.
        Button {
            OpenWithFork.open(url: url, appURL: nil, appState: appState)
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Label("Reveal in Finder", systemImage: "magnifyingglass")
        }
        Divider()
        // The submenu's own rows carry each app's real icon, so this one gets a
        // glyph to match the rest of the top level — see the note in
        // SelectionActionsMenu on the all-or-nothing rule.
        Menu {
            OpenWithItems(url: url)
        } label: {
            Label("Open With", systemImage: "app.badge")
        }
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

/// The contents of an "Open With" submenu — each registered app with its icon
/// (the default app first and marked), then a divider and "Other…". Reused by
/// the grid tile context menu and the hero viewer's Share dropdown so both read
/// like Finder's native submenu.
struct OpenWithItems: View {
    let url: URL
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let apps = OpenWithMenu.applications(for: url)
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)?.standardizedFileURL
        // Default app first, the rest alphabetical (as in Finder).
        let ordered = apps.sorted { a, b in
            if a.standardizedFileURL == defaultApp { return true }
            if b.standardizedFileURL == defaultApp { return false }
            return a.deletingPathExtension().lastPathComponent
                .localizedCaseInsensitiveCompare(b.deletingPathExtension().lastPathComponent) == .orderedAscending
        }

        ForEach(ordered, id: \.self) { appURL in
            Button {
                open(with: appURL)
            } label: {
                Label {
                    Text(appURL.deletingPathExtension().lastPathComponent
                         + (appURL.standardizedFileURL == defaultApp ? " (default)" : ""))
                } icon: {
                    Image(nsImage: Self.menuIcon(for: appURL))
                        .renderingMode(.original)
                }
            }
        }
        if !ordered.isEmpty { Divider() }
        Button("Other…") { chooseOther() }
    }

    /// App icon sized to a native menu glyph (~16pt) — the raw NSWorkspace icon
    /// is 32pt+, which inflates every menu row.
    private static func menuIcon(for appURL: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let small = icon.copy() as! NSImage
        small.size = NSSize(width: 16, height: 16)
        return small
    }

    private func open(with appURL: URL) {
        OpenWithFork.open(url: url, appURL: appURL, appState: appState)
    }

    /// Pick an app not in the registered list, like Finder's "Other…".
    private func chooseOther() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Open")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        open(with: app)
    }
}
