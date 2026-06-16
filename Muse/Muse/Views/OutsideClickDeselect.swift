//
//  OutsideClickDeselect.swift
//  Muse
//
//  Clears the grid selection when the user clicks anywhere OUTSIDE the grid's
//  scroll view (sidebar, search, toolbar, window chrome). Placed inside the
//  grid scroll content so `enclosingScrollView` resolves to the grid; a
//  window-level left-mouse-down monitor compares the click against that scroll
//  view's frame. Clicks INSIDE the grid are left to the tiles (select) and the
//  grid background (its own deselect), so this never interferes with
//  multi-select. The monitor doesn't consume the event.
//

import SwiftUI
import AppKit

struct OutsideClickDeselect: NSViewRepresentable {
    var onOutsideClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onOutsideClick = onOutsideClick
        context.coordinator.install(v)
        return v
    }
    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onOutsideClick = onOutsideClick
    }
    static func dismantleNSView(_ nsView: CatcherView, coordinator: Coordinator) {
        coordinator.remove()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?
        func install(_ view: CatcherView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak view] event in
                view?.handle(event)
                return event   // observe only; don't consume the click
            }
        }
        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    final class CatcherView: NSView {
        var onOutsideClick: () -> Void = {}

        func handle(_ event: NSEvent) {
            guard let scrollView = enclosingScrollView,
                  let window = self.window,
                  event.window === window else { return }
            // Grid scroll view's frame in window (base) coordinates.
            let gridFrame = scrollView.convert(scrollView.bounds, to: nil)
            if !gridFrame.contains(event.locationInWindow) {
                onOutsideClick()
            }
        }
    }
}
