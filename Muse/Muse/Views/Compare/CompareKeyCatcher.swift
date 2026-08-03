//
//  CompareKeyCatcher.swift
//  Muse
//
//  The compare loop: arrows swap the focused pane's candidate, Tab cycles
//  focus, 1-5/0 rate, and P toggles peaking.
//
//  A NEW sibling of `KeyCaptureView`, not an extension of it — that view has
//  three FIXED named closures (onLeft/onRight/onReturn) the hero's
//  arrow-flip and return path depend on, and this catcher reads plain
//  character keys. Don't merge them.
//

import AppKit
import SwiftUI

struct CompareKeyCatcher: NSViewRepresentable {
    var onArrow: (Int) -> Void        // delta: -1 previous, +1 next
    var onTab: () -> Void
    var onRating: (Int?) -> Void      // nil = clear
    var onPeakingToggle: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        updateClosures(v)
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        updateClosures(nsView)
    }

    private func updateClosures(_ v: KeyView) {
        v.onArrow = onArrow
        v.onTab = onTab
        v.onRating = onRating
        v.onPeakingToggle = onPeakingToggle
    }

    final class KeyView: NSView {
        var onArrow: ((Int) -> Void)?
        var onTab: (() -> Void)?
        var onRating: ((Int?) -> Void)?
        var onPeakingToggle: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            // Arrow keys inherently carry .function/.numericPad, so paging is
            // judged by KEYCODE, never by that flag.
            switch event.keyCode {
            case 123: onArrow?(-1); return   // left
            case 124: onArrow?(1); return    // right
            case 48:  onTab?(); return       // tab
            default: break
            }
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let chars = event.charactersIgnoringModifiers, let c = chars.first else {
                super.keyDown(with: event)
                return
            }
            switch c {
            case "0": onRating?(nil)
            case "1"..."5": onRating?(Int(String(c)))
            case "p", "P": onPeakingToggle?()
            default: super.keyDown(with: event)
            }
        }
    }
}
