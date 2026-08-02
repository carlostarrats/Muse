//
//  ShareButton.swift
//  Muse
//
//  Presents the standard macOS share sheet (AirDrop, Mail, Messages,
//  Save to Files, …) anchored to the button. The OS owns the transfer —
//  no entitlement, no network surface for the app.
//
//  Styled to match ChromeCircleButton in HeroImageViewer.swift: 38pt
//  circle, white-glass fill (.10 rest / .24 hover), same icon weight.
//

import SwiftUI
import AppKit

struct ShareButton: View {
    @EnvironmentObject private var appState: AppState
    let url: URL
    /// nil in Preview (white glass); the editor's resolved ink in Edit.
    var ink: PanelContrast.Ink? = nil
    @State private var hovering = false

    /// Raster kinds only — the social render pipeline re-encodes pixels, so a
    /// PDF or a video has nothing to export.
    private var isRasterKind: Bool {
        switch AssetKind.detect(at: url) {
        case .image, .raw, .psd: return true
        default: return false
        }
    }

    var body: some View {
        Menu {
            Button("Share") { share() }
            Button("Export for Social…") {
                appState.socialExportRequest = SocialExportRequest(urls: [url])
            }
            .disabled(isRasterKind == false)
            Divider()
            Button("Open") { NSWorkspace.shared.open(url) }
            // Native-style Open With submenu (app icons + default + Other…),
            // shared with the grid tile context menu.
            Menu("Open With") { OpenWithItems(url: url) }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ChromeStyle.glyph(ink, hovering: hovering))
                .frame(width: 38, height: 38)
                .background(Circle().fill(ChromeStyle.fill(ink, hovering: hovering)))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Share")
        .accessibilityLabel("Share")
    }

    private func share() {
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        // Pixels leaving the app render through OutputRender (identity today).
        guard let rendered = try? OutputRender.forOutput(url) else { return }
        // Not discarded here — the picker reads the file lazily once the user
        // picks a service. Same rule as SelectionMenu.share().
        let picker = NSSharingServicePicker(items: [rendered.url])
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }
}
