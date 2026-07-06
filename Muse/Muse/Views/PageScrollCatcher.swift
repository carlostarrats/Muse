//
//  PageScrollCatcher.swift
//  Muse
//
//  Invisible bridge that gives a SwiftUI ScrollView native Page Up / Page Down
//  support. Placed INSIDE the scroll content, it resolves the backing
//  NSScrollView via `enclosingScrollView` (the documented, non-fragile way) and
//  scrolls its clip view by one page using the pure PageScroll math.
//
//  Key delivery uses the same first-responder + keyDown pattern as
//  KeyCaptureView (proven in the hero viewer). It claims first responder when
//  the grid appears and reclaims it on a click anywhere in the scroll view, so
//  paging keeps working after the user clicks the sidebar or a tile — without
//  ever stealing focus from a text field (the search box). `isActive` gates
//  when paging should act (false while a hero viewer covers the grid).
//

import SwiftUI
import AppKit

/// What `GridView` returns from `onArrow` so the catcher can auto-scroll the new
/// highlighted tile into view. `tileTopInViewport` = canvasMinY + frames[i].minY
/// (the tile top relative to the visible viewport); height is the tile's frame
/// height. nil is returned for a no-op move (edge / empty), and no scroll happens.
struct KeyboardScrollTarget {
    let tileTopInViewport: CGFloat
    let tileHeight: CGFloat
}

struct PageScrollCatcher: NSViewRepresentable {
    var isActive: () -> Bool
    /// Plain-arrow navigation: move the highlighted tile in `direction`, returning
    /// the new tile's scroll target (or nil for a no-op). GridView owns the frames.
    var onArrow: (GridKeyboardNav.Direction) -> KeyboardScrollTarget? = { _ in nil }
    /// Plain-Space open: open the highlighted tile (hero viewer / navigate-in for
    /// a folder) — the same path as double-click.
    var onSpace: () -> Void = {}

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.isActive = isActive
        v.onArrow = onArrow
        v.onSpace = onSpace
        v.grabFocusSoon()
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.isActive = isActive
        // Reassign every update: these closures capture GridView's value-type
        // @State (frames, canvasMinY), so they must be refreshed after a relayout
        // or scroll — same reason `isActive` is reassigned here.
        nsView.onArrow = onArrow
        nsView.onSpace = onSpace
        // Re-claim focus when paging becomes active again (e.g. a hero viewer
        // just closed) so Page keys resume without needing a grid click.
        let active = isActive()
        if active && !nsView.lastActive {
            nsView.grabFocusSoon()
        }
        nsView.lastActive = active
    }

    final class CatcherView: NSView {
        var isActive: () -> Bool = { false }
        var onArrow: (GridKeyboardNav.Direction) -> KeyboardScrollTarget? = { _ in nil }
        var onSpace: () -> Void = {}
        var lastActive = false
        private var clickMonitor: Any?

        // Page Up / Page Down. On full keyboards these are dedicated keys; on
        // Mac laptops the physical Fn+Up / Fn+Down REMAPS to these very keycodes
        // (116/121) at the OS layer. So paging is detected by keycode alone —
        // NOT by the .function flag, because the plain arrow keys (below) ALSO
        // carry .function inherently (they're navigation-group keys), and a
        // flag-based test would fire on every plain arrow.
        private static let pageUpKey: UInt16 = 116
        private static let pageDownKey: UInt16 = 121
        // The four arrow keys — always plain navigation (move the highlight).
        private static let upArrowKey: UInt16 = 126
        private static let downArrowKey: UInt16 = 125
        private static let leftArrowKey: UInt16 = 123
        private static let rightArrowKey: UInt16 = 124
        private static let spaceKey: UInt16 = 49

        override var acceptsFirstResponder: Bool { true }

        /// Become first responder once the view is in a window.
        func grabFocusSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                if !(window.firstResponder is NSText) {
                    window.makeFirstResponder(self)
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Reclaim first responder when the user clicks inside this scroll
            // view (e.g. after visiting the sidebar), so Page keys keep working.
            // A click in a text field leaves the field editor focused.
            if window != nil, clickMonitor == nil {
                clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                    guard let self, let window = self.window, window.isKeyWindow,
                          self.isActive(), let scrollView = self.enclosingScrollView
                    else { return event }
                    // Is the click inside this grid's scroll view?
                    let pointInSV = scrollView.convert(event.locationInWindow, from: nil)
                    if scrollView.bounds.contains(pointInSV) {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, let window = self.window else { return }
                            if !(window.firstResponder is NSText)
                                && window.firstResponder !== self {
                                window.makeFirstResponder(self)
                            }
                        }
                    }
                    return event
                }
            } else if window == nil, let m = clickMonitor {
                NSEvent.removeMonitor(m)
                clickMonitor = nil
            }
        }

        deinit {
            if let m = clickMonitor { NSEvent.removeMonitor(m) }
        }

        override func keyDown(with event: NSEvent) {
            let key = event.keyCode
            // CRUCIAL: the ARROW keys THEMSELVES carry .function (they're in the
            // function/navigation key group) AND .numericPad — so "plain arrow"
            // must be judged WITHOUT .function/.numericPad, else every plain arrow
            // reads as a modified key. Meaningful modifiers = ⌘/⌥/⌃/⇧ only.
            let mods = event.modifierFlags.intersection(
                [.command, .option, .control, .shift])

            // Page Up / Page Down — the DEDICATED keycodes. On Mac laptops the
            // physical Fn+Up / Fn+Down remaps to these very keycodes, so we detect
            // paging by keycode alone (NOT by the .function flag, which plain
            // arrows also set — the old flag test fired on every plain arrow).
            let isPageUp = key == Self.pageUpKey
            let isPageDown = key == Self.pageDownKey
            if (isPageUp || isPageDown), mods.isEmpty, isActive(),
               let scrollView = enclosingScrollView {
                pageScroll(scrollView, pageUp: isPageUp)
                return
            }

            // Plain arrows (NO ⌘/⌥/⌃/⇧/Fn) MOVE the highlighted tile + auto-scroll.
            // This replaces the old plain-arrow line-scroll (which happened via the
            // forward-down-the-chain fallback below).
            let isArrow = key == Self.upArrowKey || key == Self.downArrowKey
                || key == Self.leftArrowKey || key == Self.rightArrowKey
            if isArrow, mods.isEmpty, isActive() {
                let direction: GridKeyboardNav.Direction
                switch key {
                case Self.upArrowKey:    direction = .up
                case Self.downArrowKey:  direction = .down
                case Self.leftArrowKey:  direction = .left
                default:                 direction = .right
                }
                if let target = onArrow(direction) {
                    scrollToReveal(target)
                }
                return  // consume — never line-scroll on a plain arrow now
            }

            // Plain Space opens the highlighted tile (hero viewer) — same as a
            // double-click. Inactive while a hero viewer covers the grid.
            if key == Self.spaceKey, mods.isEmpty, isActive() {
                onSpace()
                return
            }

            // Not ours — forward down the responder chain (letters, ⌘A Select
            // All, ⇧/⌘/⌥+arrow, and other keys) instead of dead-ending in a beep.
            if let next = nextResponder {
                next.keyDown(with: event)
            } else {
                super.keyDown(with: event)
            }
        }

        /// One-page clip-view scroll (Page Up/Down / Fn+Up/Down). Unchanged from
        /// the original keyDown body — extracted so keyDown stays readable.
        private func pageScroll(_ scrollView: NSScrollView, pageUp: Bool) {
            let clip = scrollView.contentView
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let newY = PageScroll.newOriginY(
                currentY: clip.bounds.origin.y,
                viewportHeight: clip.bounds.height,
                documentHeight: documentHeight,
                pageUp: pageUp)
            guard abs(newY - clip.bounds.origin.y) > 0.5 else {
                scrollView.flashScrollers()   // already at the edge — still show position
                return
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: newY))
            }
            scrollView.reflectScrolledClipView(clip)
            scrollView.flashScrollers()
        }

        /// Auto-scroll so the newly highlighted tile is on screen, using the pure
        /// GridScrollReveal math over live clip/document values.
        private func scrollToReveal(_ target: KeyboardScrollTarget) {
            guard let scrollView = enclosingScrollView else { return }
            let clip = scrollView.contentView
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let newY = GridScrollReveal.newOriginY(
                clipOriginY: clip.bounds.origin.y,
                viewportHeight: clip.bounds.height,
                documentHeight: documentHeight,
                tileTopInViewport: target.tileTopInViewport,
                tileHeight: target.tileHeight,
                margin: 24)
            guard abs(newY - clip.bounds.origin.y) > 0.5 else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: newY))
            }
            scrollView.reflectScrolledClipView(clip)
        }
    }
}
