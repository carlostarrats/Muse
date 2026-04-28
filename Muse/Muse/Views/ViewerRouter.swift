//
//  ViewerRouter.swift
//  Muse
//
//  Routes a FileNode to the right viewer for its AssetKind.
//  Phase 0.5: ImageViewer for images, QuickLookFallback for everything
//  else. Phase 1+ adds PDFViewer, TextViewer, MarkdownViewer, etc.
//

import SwiftUI

struct ViewerRouter: View {
    let file: FileNode

    var body: some View {
        switch file.kind {
        case .image:
            ImageViewer(file: file)
        case .raw, .psd:
            // Phase 1: dedicated RAW/PSD viewers. For now, Quick Look handles them.
            qlOverlay
        default:
            qlOverlay
        }
    }

    @ViewBuilder
    private var qlOverlay: some View {
        QuickLookOverlay(file: file)
    }
}

private struct QuickLookOverlay: View {
    @EnvironmentObject var appState: AppState
    let file: FileNode

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { appState.selectedFile = nil }

            QuickLookFallback(url: file.url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 12)
                .padding(40)
        }
    }
}
