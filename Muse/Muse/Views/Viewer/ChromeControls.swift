//
//  ChromeControls.swift
//  Muse
//
//  The viewer's floating chrome: the zoom pill's − / ＋ segments, the "Fit"
//  text button, and the circular ✕. Shared, because Edit mode grew the same
//  row — zoom, Fit, hide-UI, Share, close — and two copies of a 38pt
//  white-glass capsule would have drifted within a release.
//
//  Every control takes an optional `PanelContrast.Ink`. nil is the Preview
//  page's white glass over the image's dark wash; non-nil is Edit mode, where
//  the backdrop is the user's own white → black choice and the chrome has to
//  meet AA against it exactly like the panels do.
//

import SwiftUI

/// 38pt circular button (the ✕), hover-brightening.
struct ChromeCircleButton: View {
    let systemName: String
    var ink: PanelContrast.Ink? = nil
    /// Draws inverted — a filled ink disc with a knocked-out glyph — for a
    /// toggle that is currently ON.
    var isSelected: Bool = false
    var accessibilityLabel: String? = nil
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? ChromeStyle.knockout(ink)
                                            : ChromeStyle.glyph(ink, hovering: hovering))
                .frame(width: 38, height: 38)
                .background(Circle().fill(isSelected ? ChromeStyle.selectedFill(ink)
                                                     : ChromeStyle.fill(ink, hovering: hovering)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel
                            ?? (systemName == "xmark" ? String(localized: "Close") : systemName))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .onHover { hovering = $0 }
    }
}

/// − / ＋ segments inside the zoom pill.
struct ChromePillButton: View {
    let systemName: String
    var disabled: Bool = false
    var ink: PanelContrast.Ink? = nil
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                // Greyed when the zoom limit is reached — no hover lift, no fill.
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(disabled ? ChromeStyle.base(ink).opacity(0.25)
                                          : ChromeStyle.glyph(ink, hovering: hovering, rest: 0.7))
                .frame(width: 34, height: 38)
                .contentShape(Rectangle())
                // Explicit shape, not the bare-ShapeStyle background — that
                // overload ignores safe-area edges and smears the hover fill
                // into a full-height band beside the hidden toolbar area.
                .background(Rectangle().fill(hovering && !disabled
                                             ? ChromeStyle.raised(ink) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(systemName == "minus" ? String(localized: "Zoom out")
                            : systemName == "plus" ? String(localized: "Zoom in") : systemName)
        .onHover { hovering = $0 }
    }
}

/// 38pt-tall capsule text button ("Fit").
struct ChromeTextButton: View {
    let label: String
    var ink: PanelContrast.Ink? = nil
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ChromeStyle.glyph(ink, hovering: hovering))
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(Capsule(style: .continuous)
                    .fill(ChromeStyle.fill(ink, hovering: hovering)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The one place the chrome's two colour worlds are reconciled.
enum ChromeStyle {
    static func base(_ ink: PanelContrast.Ink?) -> Color { ink?.baseColor ?? .white }

    static func glyph(_ ink: PanelContrast.Ink?, hovering: Bool, rest: Double = 0.85) -> Color {
        base(ink).opacity(hovering ? 1.0 : rest)
    }

    /// The pill/circle's own surface. In Edit this is the panels' card fill, so
    /// the chrome and the cards are the same material.
    static func fill(_ ink: PanelContrast.Ink?, hovering: Bool) -> Color {
        guard let ink else { return .white.opacity(hovering ? 0.24 : 0.10) }
        return hovering ? ink.raisedFill(0.24) : ink.cardFill
    }

    /// A hover wash on top of an existing surface.
    static func raised(_ ink: PanelContrast.Ink?) -> Color {
        ink?.raisedFill(0.20) ?? .white.opacity(0.20)
    }

    /// A toggle that is ON: solid ink, so it reads as inverted at a glance.
    static func selectedFill(_ ink: PanelContrast.Ink?) -> Color {
        base(ink).opacity(0.92)
    }

    /// The glyph sitting on `selectedFill` — the opposite of the ink.
    static func knockout(_ ink: PanelContrast.Ink?) -> Color {
        guard let ink else { return .black.opacity(0.85) }
        return ink.isDark ? .white : .black
    }
}
