//
//  ModalChrome.swift
//  Muse
//
//  The shared look and presentation of Muse's modals: a dimming scrim with a
//  centred card on top, laid out INSIDE the window rather than in a sheet's own
//  window.
//
//  Why not `.sheet`: a sheet gets its own window, so its height can only be
//  capped by reading the parent — and an AppKit view can't find that parent
//  until it's inserted into a hierarchy, one runloop AFTER the first layout.
//  That frame drew at full height, spilled past a short window's bottom edge,
//  and the measurement then snapped it back (owner-reported on the Info sheet).
//  Here the host is handed the window's size by a `GeometryReader` during the
//  first layout, so the card's height is a `maxHeight` CAP rather than a
//  measured frame: it takes its natural height up to the cap and its own
//  ScrollView scrolls past that. There is nothing to measure and nothing to
//  snap. (Same structure as Lineform's in-window Settings modal.)
//
//  Every card keeps its growable content in a `ScrollView`/`Form`, and action
//  rows (Cancel/Update) stay OUTSIDE that scroll so they're always reachable.
//

import SwiftUI

enum ModalChrome {
    /// Card geometry + entrance motion, shared so every modal animates alike.
    static let cornerRadius: CGFloat = 20
    static let animationDuration = 0.24
    static let entranceYOffset: CGFloat = 10
    /// Gap kept between the card and the window edge on every side.
    static let margin: CGFloat = 24
    /// Floors so the card stays usable if the window is absurdly small — it
    /// shrinks with the window right down to these, and only then overhangs.
    static let minWidth: CGFloat = 280
    static let minHeight: CGFloat = 160

    static func scrimColor(for palette: MoodPalette) -> Color {
        // A dark wash under both schemes: on a light mood it reads as shadow,
        // on a dark one it deepens. Tuned so the grid stays legible as depth
        // rather than as clutter.
        Color.black.opacity(palette.scheme == .dark ? 0.55 : 0.34)
    }

    /// Card fill: a vertical wash a step lighter than the mood's own surfaces,
    /// so the card lifts off the scrimmed grid in either scheme.
    static func cardFill(for palette: MoodPalette) -> LinearGradient {
        let dark = palette.scheme == .dark
        return LinearGradient(
            colors: dark
                ? [Color(red: 0.192, green: 0.192, blue: 0.192),
                   Color(red: 0.125, green: 0.125, blue: 0.125)]
                : [Color(red: 1.0, green: 1.0, blue: 1.0),
                   Color(red: 0.945, green: 0.945, blue: 0.945)],
            startPoint: .top, endPoint: .bottom)
    }

    static func cardStroke(for palette: MoodPalette) -> Color {
        palette.scheme == .dark ? .white.opacity(0.14) : .black.opacity(0.08)
    }

    /// The card's width for a given window width: its ideal, shrinking with the
    /// window once there isn't room, never below `minWidth`.
    static func cardWidth(ideal: CGFloat, available: CGFloat) -> CGFloat {
        min(ideal, max(minWidth, available - margin * 2))
    }

    /// The card's height CAP for a given window height. Not a fixed height —
    /// the card is content-sized up to this, then scrolls.
    static func cardMaxHeight(available: CGFloat) -> CGFloat {
        max(minHeight, available - margin * 2)
    }
}

/// The dimming, click-to-dismiss layer behind a modal card.
struct ModalScrim: View {
    let palette: MoodPalette
    let dismiss: () -> Void

    var body: some View {
        ModalChrome.scrimColor(for: palette)
            .ignoresSafeArea()
            // Absorbs every click that isn't on the card — both to dismiss and
            // to stop the grid behind from taking selections.
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
            .accessibilityHidden(true)
    }
}
