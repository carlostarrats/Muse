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

struct PageScrollCatcher: NSViewRepresentable {
    var isActive: () -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.isActive = isActive
        v.grabFocusSoon()
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.isActive = isActive
    }

    final class CatcherView: NSView {
        var isActive: () -> Bool = { false }
        private var clickMonitor: Any?

        // Dedicated Page Up/Down keys (full keyboards) …
        private static let pageUpKey: UInt16 = 116
        private static let pageDownKey: UInt16 = 121
        // … and the arrow keys, which become Page Up/Down on Mac keyboards
        // without dedicated keys when pressed with Fn (reported as the arrow
        // keycode + the .function modifier).
        private static let upArrowKey: UInt16 = 126
        private static let downArrowKey: UInt16 = 125

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
            let fn = event.modifierFlags.contains(.function)
            let isPageUp = key == Self.pageUpKey || (fn && key == Self.upArrowKey)
            let isPageDown = key == Self.pageDownKey || (fn && key == Self.downArrowKey)
            guard isPageUp || isPageDown,
                  isActive(), let scrollView = enclosingScrollView else {
                super.keyDown(with: event)
                return
            }
            let clip = scrollView.contentView
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let newY = PageScroll.newOriginY(
                currentY: clip.bounds.origin.y,
                viewportHeight: clip.bounds.height,
                documentHeight: documentHeight,
                pageUp: isPageUp)

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
            // Briefly show the scroll bar so the user can see where they are —
            // programmatic scrolls don't surface the overlay indicator otherwise.
            scrollView.flashScrollers()
        }
    }
}
