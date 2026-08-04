//
//  MainWindowFinder.swift
//  MuseUITests
//
//  Find the main window; do not assume what TYPE it is published as.
//
//  Every drive test opened with `app.windows.firstMatch` and waited on it. On
//  2026-08-04 that started returning nothing, and 23 tests failed saying "no
//  main window" — including `testAppLaunchesWithPopulatedSidebar`, which does
//  nothing else. The app was fine. Launched directly and queried through
//  `CGWindowListCopyWindowInfo`, it had exactly one on-screen window, layer 0,
//  1489×922, with and without the suite's launch arguments; and
//  `MuseTagChipRowTests` — same launch, same guard — passed in the same run,
//  reading 258 buttons and their frames out of that very window.
//
//  A probe settled it:
//
//      PROBE windows=0 dialogs=1 sheets=0 groups=11 buttons=258
//
//  The window is published with the AXDialog subrole, so `windows` does not
//  match it while every descendant stays perfectly reachable. `MuseApp` asks
//  for a plain `WindowGroup` and sets no window style, and the same probe
//  reports the same thing at the previous commit — so this is the platform's
//  classification changing under a suite that had hard-coded an assumption
//  about it, not a change in Muse.
//
//  This is round 9's rule with the net cast wider. That round made these tests
//  LOCATE the tile they click instead of computing its position; the same
//  reasoning applies to the window itself. A test asserts what the app DOES —
//  which element type AppKit files it under is the platform's business, and
//  matching both is free.
//
//  Kept as a wait rather than a lookup so the failure message still means what
//  it says: after this returns a non-existent element, no window of EITHER type
//  appeared within the timeout, which is a real failure worth reporting.
//

import XCTest

extension XCUIApplication {

    /// Wait for the app's main window and return it, matching either element
    /// type the platform may publish it as. Returns a non-existent element on
    /// timeout, so the caller's own assertion reports the failure.
    func awaitMainWindow(_ timeout: TimeInterval) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if windows.firstMatch.exists { return windows.firstMatch }
            if dialogs.firstMatch.exists { return dialogs.firstMatch }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return windows.firstMatch
    }
}
