//
//  PDFViewerView.swift
//  Muse
//
//  PDFKit-backed PDF viewer (Q7). View-only: scroll, zoom, search,
//  select/copy text. Annotations belong to Preview/Acrobat (Open With).
//

import SwiftUI
import PDFKit

struct PDFViewerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor.windowBackgroundColor
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}
