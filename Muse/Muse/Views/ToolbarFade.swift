//
//  ToolbarFade.swift
//  Muse
//
//  AppKit cross-fade for the native window toolbar.
//
//  The hero viewer used to hide the toolbar via SwiftUI's
//  `.toolbar(.hidden, for: .windowToolbar)`, which TEARS DOWN the native
//  NSToolbar and re-materializes it on close. That re-materialization is
//  abrupt (glass capsules + search-field shadows pop in mid-close — the
//  long-standing "flash", accepted as inherent in the 2026-06-18 session)
//  and lands a beat AFTER the close flight, leaving an empty nav strip
//  until the items appear.
//
//  This replaces the teardown with an alpha fade on the toolbar's own
//  AppKit view (`NSToolbarView`, the single view holding every item + its
//  glass platters, verified by hierarchy dump on macOS 26). The toolbar
//  stays mounted the whole time, so nothing ever re-materializes: it
//  dissolves out as the viewer opens and dissolves back in with the close
//  flight. `isHidden` is set after the fade-out so the invisible strip
//  can't swallow clicks meant for the viewer's top edge.
//
//  If the toolbar view can't be located (private hierarchy shifted, or
//  full-screen moved it out of the titlebar), both calls no-op: the
//  toolbar just stays visible — cosmetically worse, never broken.
//

import AppKit

@MainActor
enum ToolbarFade {
    /// Bumped on every call so a stale fade-out completion can't hide the
    /// toolbar after a fade-in has already superseded it.
    private static var generation = 0

    /// Dissolve the toolbar out (viewer opening). Ends fully hidden.
    static func hide(duration: TimeInterval = 0.20) {
        guard let view = toolbarView() else { return }
        generation += 1
        let expected = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 0
        }, completionHandler: {
            // NSAnimationContext completions fire on the main thread.
            MainActor.assumeIsolated {
                // Only commit the hide if no show() superseded this fade.
                if generation == expected { view.isHidden = true }
            }
        })
    }

    /// Dissolve the toolbar back in (close flight starting). Safe to call
    /// redundantly — from any state it just animates toward visible.
    ///
    /// Deliberately near-instant (0.12s, fast-start ease-out): any slower and
    /// the nav reads as EMPTY until after the image lands (NSAnimationContext's
    /// eased fade spent its first ~0.2s under 15% opacity, measured via the
    /// presentation layer — hence the explicit CABasicAnimation). A fast return
    /// does NOT cause the old close "flash": that was the hero backdrop being
    /// unmounted before its fade-out finished (fixed in HeroImageViewer), and
    /// was misattributed to the toolbar for a while.
    static func show(duration: TimeInterval = 0.12) {
        guard let view = toolbarView() else { return }
        generation += 1
        let startOpacity = view.layer?.presentation()?.opacity ?? Float(view.alphaValue)
        view.isHidden = false
        view.alphaValue = 1
        if let layer = view.layer {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = startOpacity
            anim.toValue = 1.0
            anim.duration = duration
            // Fast-start ease-out: ~50% of the fade in the first quarter of
            // the duration.
            anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.17, 0.84, 0.44, 1.0)
            layer.add(anim, forKey: "tbfade")
        }
    }

    // MARK: - Lookup

    /// The single AppKit view that renders the whole toolbar strip (items,
    /// glass platters, search field). Found by walking up from a standard
    /// window button to the titlebar container, then down to the first
    /// "toolbar"-named view — same shape on Sonoma through Tahoe.
    private static func toolbarView() -> NSView? {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil }),
              let anchor = window.standardWindowButton(.closeButton) else { return nil }
        var candidate: NSView? = anchor
        while let view = candidate,
              !String(describing: type(of: view)).contains("TitlebarContainer") {
            candidate = view.superview
        }
        guard let container = candidate else { return nil }
        return findToolbarView(in: container)
    }

    private static func findToolbarView(in root: NSView) -> NSView? {
        for sub in root.subviews {
            let name = String(describing: type(of: sub)).lowercased()
            if name.contains("toolbar"), !name.contains("titlebar") { return sub }
            if let found = findToolbarView(in: sub) { return found }
        }
        return nil
    }
}
