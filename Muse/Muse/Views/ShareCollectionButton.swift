//
//  ShareCollectionButton.swift
//  Muse
//
//  In-collection header control: a menu with "Save to…" (NSSavePanel with a
//  Paper Size dropdown, defaulted to Desktop) and "Share" (standard
//  NSSharingServicePicker). Both build a paginated PDF of the collection's
//  displayed images — Save renders at the chosen paper size after the panel is
//  confirmed; Share uses the default size. Nothing about the system share sheet
//  is customized; no new entitlement is needed.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ShareCollectionButton: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject private var googleAuth: GoogleOAuth
    let title: String
    let count: Int

    // Mirror the grid's current density (the bottom-right column slider).
    @AppStorage("gridColumnCount") private var gridColumns = 4
    @State private var hovering = false
    @State private var preparing = false
    @StateObject private var iCloudService = ICloudShareService()
    @State private var showingICloudShare = false
    @State private var showingDriveShare = false

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
            Divider()
            Button("Share iCloud Link") { startICloudShare() }
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
        // onDismiss runs reset() on EVERY dismissal path — including Escape /
        // OS-driven close — so the upload wait + query can never leak.
        .sheet(isPresented: $showingICloudShare, onDismiss: { iCloudService.reset() }) {
            ICloudShareProgressView(service: iCloudService) {
                showingICloudShare = false
            }
        }
        .sheet(isPresented: $showingDriveShare) {
            DriveShareSheet(auth: googleAuth, title: title, urls: exportURLs) {
                showingDriveShare = false
            }
        }
    }

    private func startICloudShare() {
        iCloudService.reset()
        showingICloudShare = true
        iCloudService.start(title: title, urls: exportURLs)
    }

    private func makePDF(pageSize: CGSize) async -> URL? {
        let urls = exportURLs
        let layoutAspect = appState.imageLayout.aspect
        let backdrop = appState.effectiveTileBackground
            .backdropRGB(for: appState.moodPalette)?.cgColor
        return await CollectionPDFExporter.makePDF(
            urls: urls, title: title, count: urls.count, columns: gridColumns,
            layoutAspect: layoutAspect, tileBackdrop: backdrop,
            tagLabels: appState.activeTagLabels, pageSize: pageSize)
    }

    private func save() async {
        // Show the panel (with a Paper Size dropdown) FIRST, then render at the
        // chosen size — the page size has to be known before makePDF runs.
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = "\(title).pdf"
        panel.directoryURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first
        let popup = paperSizePopup()
        panel.accessoryView = paperSizeAccessory(popup)
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        // Map the popup's selected row back through allCases (same order drove
        // the population, so the index can't drift); fall back to the default.
        let paper = PaperSize.allCases[safe: popup.indexOfSelectedItem] ?? .default

        preparing = true
        defer { preparing = false }
        guard let pdf = await makePDF(pageSize: paper.size) else { return }
        // Atomic overwrite — no pre-delete window that could destroy an
        // existing file if the write fails.
        if let data = try? Data(contentsOf: pdf) {
            try? data.write(to: dest, options: .atomic)
        }
    }

    private func share() async {
        preparing = true
        defer { preparing = false }
        // Share keeps the default 11×14; only Save to… offers a size choice.
        guard let pdf = await makePDF(pageSize: PaperSize.default.size) else { return }
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [pdf])
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }

    // MARK: - Paper-size accessory view

    /// A popup listing every `PaperSize` (in `allCases` order), preselected to
    /// the default — the read-back in `save()` relies on this same order. Width
    /// is governed by the 260 pt minimum in `paperSizeAccessory`; the centered
    /// stack never stretches it past that.
    private func paperSizePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        for paper in PaperSize.allCases { popup.addItem(withTitle: paper.displayName) }
        popup.selectItem(at: PaperSize.allCases.firstIndex(of: .default) ?? 0)
        return popup
    }

    /// "Paper Size:" label + the popup as a compact row, centered in the
    /// panel-width accessory band (the panel stretches the container, so the
    /// inner stack is centered rather than pinned to both edges — keeping the
    /// popup at its intrinsic width instead of running the full panel width).
    private func paperSizeAccessory(_ popup: NSPopUpButton) -> NSView {
        let label = NSTextField(labelWithString: String(localized: "Paper Size:"))
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 44),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            // Comfortable minimum width — roomier than the popup's intrinsic
            // size without stretching to the full panel width.
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        return container
    }
}

private extension Array {
    /// Bounds-checked index — nil instead of a crash for an out-of-range row.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
