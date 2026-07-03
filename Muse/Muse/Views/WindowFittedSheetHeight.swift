//
//  WindowFittedSheetHeight.swift
//  Muse
//
//  Sizes a fixed-width reading/layout sheet (About, Image Layout) to an
//  ideal height, but NEVER taller than the window it's presented over —
//  so on a short window the sheet shrinks to fit instead of spilling past
//  the window's bottom edge. Both target sheets wrap their content in a
//  ScrollView, so the capped height just scrolls; nothing is clipped away.
//
//  A macOS `.sheet` sizes itself to its content's fitting size, which is
//  why a bare `.frame(height: 720)` overflows a 600-tall window. This reads
//  the PARENT window height (the sheet's own window is content-sized, so we
//  climb to `sheetParent`) and updates live as the user resizes.
//

import SwiftUI
import AppKit

extension View {
    /// Fixes width, sets an `ideal` height, but caps the height at the
    /// presenting window's content height minus `margin` — so the sheet
    /// stays inside a short window. `minHeight` keeps it usable if the
    /// window is tiny.
    func windowFittedSheetHeight(width: CGFloat,
                                 ideal: CGFloat,
                                 minHeight: CGFloat = 320,
                                 margin: CGFloat = 24) -> some View {
        modifier(WindowFittedSheetHeight(width: width,
                                         ideal: ideal,
                                         minHeight: minHeight,
                                         margin: margin))
    }
}

private struct WindowFittedSheetHeight: ViewModifier {
    let width: CGFloat
    let ideal: CGFloat
    let minHeight: CGFloat
    let margin: CGFloat
    @State private var windowHeight: CGFloat?

    func body(content: Content) -> some View {
        let height = SheetFit.height(ideal: ideal,
                                     windowHeight: windowHeight,
                                     minHeight: minHeight,
                                     margin: margin)
        content
            .frame(width: width, height: height)
            .background(SheetParentHeightReader(height: $windowHeight))
    }
}

/// Reports the presenting (parent) window's content-area height, live on resize.
private struct SheetParentHeightReader: NSViewRepresentable {
    @Binding var height: CGFloat?

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHeight = { height = $0 }
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        var onHeight: ((CGFloat) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Defer one runloop turn: reading `sheetParent` and writing the
            // SwiftUI @State binding can otherwise happen inside AppKit's
            // hierarchy-insertion pass (part of the SwiftUI update), tripping
            // "modifying state during view update". The hop also gives the
            // sheet time to attach so `sheetParent` is populated.
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        /// Find the window this sheet is presented over. The sheet's own window
        /// is content-sized (circular), so climb to its `sheetParent`. If that
        /// isn't set (not presented as a sheet), leave the height unmeasured so
        /// the modifier falls back to its ideal height.
        private func attach() {
            guard let parent = window?.sheetParent else { return }
            observe(parent)
        }

        private func observe(_ parent: NSWindow) {
            report(parent)
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: parent,
                queue: .main
            ) { [weak self] _ in self?.report(parent) }
        }

        private func report(_ parent: NSWindow) {
            onHeight?(parent.contentLayoutRect.height)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
