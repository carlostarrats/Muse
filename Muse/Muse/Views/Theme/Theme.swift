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
