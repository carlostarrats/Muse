//
//  WindowFittedSheetHeight.swift
//  Muse
//
//  Sizes a fixed-width card sheet to an ideal height, but NEVER taller than
//  the window it's presented over (nor than the screen's visible area) — so on
//  a short window the sheet shrinks to fit instead of spilling past the bottom
//  edge. Every sheet using this wraps its growable content in a ScrollView or
//  Form, so the capped height just scrolls; nothing is clipped away.
//
//  A macOS `.sheet` sizes itself to its content's fitting size, which is
//  why a bare `.frame(height: 720)` overflows a 600-tall window. This reads
//  the PARENT window height (the sheet's own window is content-sized, so we
//  climb to `sheetParent`) and updates live as the user resizes.
//
//  The cap must be right on the FIRST layout, not one runloop later: the
//  AppKit reader can't find the parent window until it's in a hierarchy, and
//  falling back to the ideal height for that frame made the sheet visibly open
//  oversized and then snap in. `availableHeight` resolves a synchronous value
//  up front and the reader refines it.
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
        // The AppKit reader below can't find the parent window until it has been
        // inserted into a hierarchy — a runloop AFTER this first layout. Falling
        // back to `ideal` for that frame drew the sheet at full height, spilling
        // past a short window's bottom edge, and the measurement then snapped it
        // back: the owner-reported "extends out, then clips to be inside".
        //
        // So resolve a height SYNCHRONOUSLY for the first layout instead. A sheet
        // is key but never main, so `NSApp.mainWindow` is still the window it's
        // being presented over. The live reader refines this and tracks resizes.
        let available = Self.availableHeight(measured: windowHeight)
        let height = SheetFit.height(ideal: ideal,
                                     windowHeight: available,
                                     minHeight: minHeight,
                                     margin: margin)
        content
            .frame(width: width, height: height)
            .background(SheetParentHeightReader(height: $windowHeight))
    }

    /// The height the sheet has to live inside: the presenting window, further
    /// bounded by the screen's visible area (a window can be taller than the
    /// screen or hang off its bottom, and the sheet has to stay on screen —
    /// being inside the window isn't enough if the window isn't).
    private static func availableHeight(measured: CGFloat?) -> CGFloat? {
        let window = measured ?? presentingWindowHeight()
        let screen = NSScreen.main?.visibleFrame.height
        return [window, screen].compactMap { $0 }.min()
    }

    /// Best-effort synchronous read of the presenting window, for the first
    /// layout only. `mainWindow` first (a sheet never becomes main), then any
    /// visible non-sheet window as a fallback.
    private static func presentingWindowHeight() -> CGFloat? {
        if let main = NSApp.mainWindow {
            return main.contentLayoutRect.height
        }
        return NSApp.windows
            .first { $0.isVisible && $0.sheetParent == nil && !$0.isSheet }?
            .contentLayoutRect.height
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
