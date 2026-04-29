//
//  QuickLookFallback.swift
//  Muse
//
//  Universal fallback viewer using QuickLook for any AssetKind without a
//  dedicated viewer. Wraps QLPreviewView in an NSViewRepresentable.
//

import SwiftUI
import Quartz

struct QuickLookFallback: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as QLPreviewItem
        view.autostarts = true
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as QLPreviewItem
    }
}
