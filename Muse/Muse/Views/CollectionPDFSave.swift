//
//  CollectionPDFSave.swift
//  Muse
//
//  Shared "Save to…" PDF export — the NSSavePanel + Paper Size accessory +
//  atomic write, used by both `ShareCollectionButton` (the currently OPEN
//  collection) and `CollectionSidebarRow`'s context menu (an arbitrary
//  collection by id, not necessarily open). Renders via
//  `CollectionPDFExporter` using the app's current GLOBAL grid state
//  (columns/layout/backdrop) — these aren't per-collection, so reusing
//  `appState`'s live values is correct for either caller.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
enum CollectionPDFSave {
    enum Outcome { case success, cancelled, failed }

    static func run(
        title: String, urls: [URL], appState: AppState, gridColumns: Int,
        tagLabels: [String] = []
    ) async -> Outcome {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = "\(title).pdf"
        panel.directoryURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first
        let popup = paperSizePopup()
        panel.accessoryView = paperSizeAccessory(popup)
        guard panel.runModal() == .OK, let dest = panel.url else { return .cancelled }

        // Map the popup's selected row back through allCases (same order drove
        // the population, so the index can't drift); fall back to the default.
        let paper = PaperSize.allCases[safe: popup.indexOfSelectedItem] ?? .default
        let layoutAspect = appState.imageLayout.aspect
        let backdrop = appState.effectiveTileBackground
            .backdropRGB(for: appState.moodPalette)?.cgColor
        guard let pdf = await CollectionPDFExporter.makePDF(
            urls: urls, title: title, count: urls.count, columns: gridColumns,
            layoutAspect: layoutAspect, tileBackdrop: backdrop,
            tagLabels: tagLabels, pageSize: paper.size
        ) else { return .failed }
        do {
            // Atomic overwrite — no pre-delete window that could destroy an
            // existing file if the write fails.
            let data = try Data(contentsOf: pdf)
            try data.write(to: dest, options: .atomic)
            return .success
        } catch {
            return .failed
        }
    }

    // MARK: - Paper-size accessory view

    /// A popup listing every `PaperSize` (in `allCases` order), preselected to
    /// the default — the read-back in `run` relies on this same order. Width
    /// is governed by the 260 pt minimum in `paperSizeAccessory`; the centered
    /// stack never stretches it past that.
    private static func paperSizePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        // The "Paper Size:" NSTextField is only a visual neighbor — not
        // programmatically associated — so VoiceOver needs the role spelled out.
        popup.setAccessibilityLabel(String(localized: "Paper Size"))
        for paper in PaperSize.allCases { popup.addItem(withTitle: paper.displayName) }
        popup.selectItem(at: PaperSize.allCases.firstIndex(of: .default) ?? 0)
        return popup
    }

    /// "Paper Size:" label + the popup as a compact row, centered in the
    /// panel-width accessory band (the panel stretches the container, so the
    /// inner stack is centered rather than pinned to both edges — keeping the
    /// popup at its intrinsic width instead of running the full panel width).
    private static func paperSizeAccessory(_ popup: NSPopUpButton) -> NSView {
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
