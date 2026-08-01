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
    /// Arbitrary key passthrough — return true to CONSUME the event. Added for
    /// the editor's J (zebras); the three hardcoded handlers stay because
    /// arrows and return are what every caller wants.
    var onKey: ((UInt16) -> Bool)?

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.onLeft = onLeft; v.onRight = onRight; v.onReturn = onReturn; v.onKey = onKey
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onLeft = onLeft; nsView.onRight = onRight; nsView.onReturn = onReturn
        nsView.onKey = onKey
    }

    final class KeyView: NSView {
        var onLeft: (() -> Void)?
        var onRight: (() -> Void)?
        var onReturn: (() -> Void)?
        var onKey: ((UInt16) -> Bool)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if onKey?(event.keyCode) == true { return }
            switch event.keyCode {
            case 123: onLeft?()
            case 124: onRight?()
            case 36:  onReturn?()
            default:  super.keyDown(with: event)
            }
        }
    }
}
