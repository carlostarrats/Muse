//
//  KeyCaptureView.swift
//  Muse
//
//  Minimal NSView key capture for arrows/return — the hero viewer's
//  arrow-key flipping (and anything else that needs raw key events
//  without focus rings).
//

import SwiftUI
import AppKit

struct KeyCaptureView: NSViewRepresentable {
    var onLeft: () -> Void
    var onRight: () -> Void
    var onReturn: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.onLeft = onLeft; v.onRight = onRight; v.onReturn = onReturn
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onLeft = onLeft; nsView.onRight = onRight; nsView.onReturn = onReturn
    }

    final class KeyView: NSView {
        var onLeft: (() -> Void)?
        var onRight: (() -> Void)?
        var onReturn: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123: onLeft?()
            case 124: onRight?()
            case 36:  onReturn?()
            default:  super.keyDown(with: event)
            }
        }
    }
}
