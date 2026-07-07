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
//  Full-screen is handled deliberately, NOT by accident: macOS relocates the
//  NSToolbarView out of the window titlebar into a separate auto-hiding
//  NSToolbarFullScreenWindow whose visibility the OS owns (it slides down on
//  mouse-to-top). `toolbarView()` returns nil for a full-screen window, so both
//  calls no-op and we never touch that OS-managed view — fading or hiding it
//  would fight the auto-hide and could strand the toolbar hidden after
//  full-screen exits (the view is reused when it returns to the titlebar). In
//  full-screen the toolbar auto-hides on its own and there is no teardown, so
//  there is no flash to prevent anyway.
//
//  If the toolbar view can't be located for any other reason (private hierarchy
//  shifted on a future macOS), both calls no-op the same way: the toolbar just
//  stays visible — cosmetically worse, never broken.
//

import AppKit

@MainActor
enum ToolbarFade {
    /// Bumped on every call so a stale fade-out completion can't hide the
    /// toolbar after a fade-in has already superseded it.
    private static var generation = 0

    /// The visibility we last INTENDED (true = hidden), recorded even when the
    /// call no-ops in full-screen. Re-applied on full-screen exit: macOS carries
    /// the hidden alpha/`isHidden` back to the windowed toolbar view (verified),
    /// so a hero that was hidden windowed, then closed while full-screen (where
    /// show() can't reach the relocated view), would otherwise strand the
    /// toolbar invisible after exiting full-screen. See `installFullScreenGuard`.
    private static var lastIntentHidden = false

    /// Dissolve the toolbar out (viewer opening). Ends fully hidden.
    static func hide(duration: TimeInterval = 0.20) {
        lastIntentHidden = true
        installFullScreenGuard()
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
        lastIntentHidden = false
        installFullScreenGuard()
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

    // MARK: - Full-screen carryover guard

    private static var fullScreenGuardInstalled = false

    /// Register once for full-screen-exit, to undo the hidden-state carryover.
    /// macOS reuses the toolbar view across the transition and brings its
    /// `alpha`/`isHidden` back with it, so on returning to the titlebar we
    /// re-assert whatever visibility we last intended (`lastIntentHidden`):
    /// - hero closed while full-screen → intent is "shown" → restore the
    ///   toolbar the stranded no-op couldn't reach.
    /// - hero still open across the transition → intent is "hidden" → keep it
    ///   hidden (the later close's show() fades it back in).
    private static func installFullScreenGuard() {
        guard !fullScreenGuardInstalled else { return }
        fullScreenGuardInstalled = true
        NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // The view is back in the titlebar now; re-assert intent with no
                // animation (the transition itself already animated). Cancel any
                // in-flight fade so it can't fight this final state.
                guard let view = toolbarView() else { return }
                view.layer?.removeAnimation(forKey: "tbfade")
                view.alphaValue = lastIntentHidden ? 0 : 1
                view.isHidden = lastIntentHidden
            }
        }
    }

    // MARK: - Lookup

    /// The single AppKit view that renders the whole toolbar strip (items,
    /// glass platters, search field). Found by walking up from a standard
    /// window button to the titlebar container, then down to the first
    /// "toolbar"-named view — same shape on Sonoma through Tahoe.
    ///
    /// Returns nil while the toolbar's window is full-screen: macOS moves the
    /// NSToolbarView into a separate auto-hiding window it manages itself, and
    /// we must not touch it there (see the file header). Bailing here keeps
    /// hide()/show() as clean no-ops in full-screen.
    private static func toolbarView() -> NSView? {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil }),
              !window.styleMask.contains(.fullScreen),
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
