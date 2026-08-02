//
//  Theme.swift
//  Muse
//
//  A minimal semantic token layer, injected once in `ContentView` and read via
//  `@Environment(\.theme)`.
//
//  Deliberately small: role-named colours, three spacings, one radius, two
//  fonts. The editor is the first surface with enough controls that repeating
//  the same four constants in a dozen views would guarantee they drift, which
//  is the only problem this solves. It is NOT a design system.
//
//  Scope rule (DECISIONS): every NEW editor-adjacent surface reads this;
//  pre-existing surfaces are NOT migrated. Non-editor code keeps the prior
//  rule — system semantic colours, the shared `SidebarView` constants,
//  `moodPalette`, and no raw hex anywhere.
//

import SwiftUI

struct Theme: Equatable {
    var panelFill: Color
    var panelStroke: Color
    /// A surface raised ON a panel card — a disclosure row, a small button.
    /// Tinted like the card (away from the text), so it can't erode the
    /// contrast the card just established. Default is the pre-panel look.
    var panelRaised: Color = Color.primary.opacity(0.08)
    var panelRaisedHover: Color = Color.primary.opacity(0.16)
    /// True when the panel's ink is BLACK (a light backdrop). Plotting surfaces
    /// read it to pick a blend mode: `.screen` paints channels onto a dark
    /// card, and paints them into invisibility on a light one.
    var panelInkIsDark: Bool = false
    /// A SELECTED row's fill, and the ink that sits on it. One solid colour on
    /// every backdrop — see PanelContrast.selectionSolidGrey.
    var selectionFill: Color = Color(nsColor: .systemBlue)
    var selectionInk: Color = .white
    /// A destructive control's fill and ink — same resolution as the selection.
    var dangerFill: Color = Color(nsColor: .systemRed)
    var dangerInk: Color = .white
    /// Slider tints, curve strokes, active toggles — the one "this is
    /// interactive" colour. Tracks the mood so the editor doesn't read as a
    /// foreign panel bolted onto the app.
    var controlAccent: Color
    var textPrimary: Color
    var textSecondary: Color

    var spacingS: CGFloat = 6
    var spacingM: CGFloat = 12
    var spacingL: CGFloat = 20
    var radius: CGFloat = 10

    var labelFont: Font = .system(size: 11, weight: .medium)
    /// Monospaced so a slider's readout doesn't jitter horizontally as digits
    /// change under a drag.
    var valueFont: Font = .system(size: 11, weight: .regular, design: .monospaced)

    static func resolve(palette: MoodPalette) -> Theme {
        Theme(
            // Translucent over the editor backdrop rather than opaque: the
            // cards float above the photo, and an opaque panel reads as a
            // second window.
            panelFill: Color(nsColor: .windowBackgroundColor).opacity(0.85),
            panelStroke: Color(nsColor: .separatorColor),
            // systemBlue, not `.accentColor`: the latter resolves to
            // `controlAccentColor`, which does NOT adapt between light and
            // dark and reads muddy on a dark backdrop — the same measured
            // finding that governs the sidebar's selection colours.
            controlAccent: Color(nsColor: .systemBlue),
            textPrimary: palette.scheme == .dark ? .white : .primary,
            textSecondary: .secondary)
    }

    /// The same tokens re-pointed at the hero viewer's translucent card — what
    /// the Preview column has always been, and what the editor's panels became
    /// when the two were unified.
    ///
    /// Not mood-derived: these cards sit on the neutral editor backdrop the
    /// USER picks (white → black), so the ink follows that choice and nothing
    /// else. The card fill is the same 0.09 at both ends.
    func onPanel(_ ink: PanelContrast.Ink) -> Theme {
        var t = self
        t.panelFill = ink.cardFill
        t.panelStroke = .clear
        t.panelRaised = ink.raisedFill(0.16)
        t.panelRaisedHover = ink.raisedFill(0.28)
        t.panelInkIsDark = ink.isDark
        t.selectionFill = ink.selectionFill
        t.selectionInk = ink.selectionInk
        t.dangerFill = ink.dangerFill
        t.dangerInk = ink.dangerInk
        t.textPrimary = ink.baseColor
        t.textSecondary = ink.secondaryText
        return t
    }

    /// Used only as the environment default, before `ContentView` injects the
    /// resolved one.
    static let fallback = Theme.resolve(
        palette: MoodPalette(backgroundRGB: MoodRGB(r: 1, g: 1, b: 1),
                             tileRGB: MoodRGB(r: 0.95, g: 0.95, b: 0.95),
                             scheme: .light))
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.fallback
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
