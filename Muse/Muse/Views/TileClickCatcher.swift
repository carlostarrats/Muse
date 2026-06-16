//
//  TileClickCatcher.swift
//  Muse
//
//  Transparent AppKit overlay that reports left-clicks with their click count
//  and modifier flags. The first click selects IMMEDIATELY (Finder-like, no
//  double-click delay); a second click within the interval opens. Right-clicks
//  are passed through so SwiftUI's .contextMenu still fires.
//

import SwiftUI
import AppKit

struct TileClickCatcher: NSViewRepresentable {
    var onSelect: (_ command: Bool, _ shift: Bool) -> Void
    var onOpen: () -> Void

    func makeNSView(context: Context) -> ClickView {
        let v = ClickView()
        v.onSelect = onSelect; v.onOpen = onOpen
        return v
    }
    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.onSelect = onSelect; nsView.onOpen = onOpen
    }

    final class ClickView: NSView {
        var onSelect: ((Bool, Bool) -> Void)?
        var onOpen: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                onOpen?()
            } else {
                let m = event.modifierFlags
                onSelect?(m.contains(.command), m.contains(.shift))
            }
        }
        // Let right-clicks fall through to SwiftUI's context menu.
        override func rightMouseDown(with event: NSEvent) {
            super.rightMouseDown(with: event)
        }
    }
}
