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
    let url: URL
    @State private var hovering = false

    var body: some View {
        Button {
            present()
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1.0 : 0.85))
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(hovering ? 0.24 : 0.10)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Share")
    }

    private func present() {
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }
}
