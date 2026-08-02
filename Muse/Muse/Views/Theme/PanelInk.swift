//
//  PanelInk.swift
//  Muse
//
//  SwiftUI colours for a resolved `PanelContrast.Ink`. The math lives in
//  Components/PanelContrast.swift and stays view-free so it can be tested;
//  this is the thin layer that turns it into Colors.
//
//  Everything drawn ON the editor backdrop — the panel cards, and the
//  Preview | Edit switch that floats over it — must come through here, or it
//  goes back to being white-on-white the moment someone picks a light backdrop.
//

import SwiftUI

extension PanelContrast.Ink {
    /// Text and glyph colour.
    var baseColor: Color { isDark ? .black : .white }

    /// The card's tint: toward the ink normally, away from it in the mid-grey
    /// dead zone where a toward-tint can't carry AA text.
    var veilColor: Color { veilOpposesInk ? (isDark ? .white : .black) : baseColor }

    /// The card fill itself.
    var cardFill: Color { veilColor.opacity(cardAlpha) }

    /// A raised fill on top of a card — a selected segment, an active row.
    /// Built from the VEIL, not the ink: tinting toward the ink would pull the
    /// surface back under the text and undo the contrast the resolver just won.
    func raisedFill(_ opacity: Double) -> Color { veilColor.opacity(opacity) }

    /// Near-opaque card drawn behind a whole panel while the canvas is zoomed.
    /// The Preview column does exactly this: translucent cards are unreadable
    /// once a bright photo is running underneath them, so zooming brings up a
    /// solid backing. Opposite the ink, so the ink still reads on it.
    var backing: Color { isDark ? Color(white: 0.97) : Color(white: 0.12) }

    /// The three blues `PanelContrast.accentGreys` is the luminance of, in the
    /// same order — systemBlue, darkened, lightened. Written out rather than
    /// blended at runtime so the greys the resolver reasons about and the
    /// colours actually drawn can't drift apart.
    /// The reds `PanelContrast.dangerGreys` is the luminance of, in order.
    static let dangerColors: [Color] = [
        Color(.sRGB, red: 1.00, green: 0.231, blue: 0.188),
        Color(.sRGB, red: 0.55, green: 0.127, blue: 0.104),
        Color(.sRGB, red: 1.00, green: 0.775, blue: 0.766),
    ]

    /// The darkened blue (index 1) is systemBlue scaled in LINEAR light, not a
    /// hand-picked navy — every channel × 0.698, which lands its luminance
    /// exactly on `accentGreys[1]` (0.42) and keeps the hue. #0067DA.
    static let accentColors: [Color] = [
        Color(.sRGB, red: 0.00, green: 0.478, blue: 1.00),
        Color(.sRGB, red: 0.00, green: 0.404, blue: 0.853),
        Color(.sRGB, red: 0.45, green: 0.713, blue: 1.00),
    ]

    /// The fill for a SELECTED row, and the ink on it — one pair per screen,
    /// so every selected thing in the editor matches. See
    /// `PanelContrast.Ink.selectionIsDarkBlue`.
    var selectionFill: Color { Self.accentColors[selectionIsDarkBlue ? 1 : 2] }
    var selectionInk: Color { selectionIsDarkBlue ? .white : .black }

    /// A destructive control's fill and the ink on it.
    var dangerFill: Color { Self.dangerColors[dangerIsDarkRed ? 1 : 2] }
    var dangerInk: Color { dangerIsDarkRed ? .white : .black }

    var secondaryText: Color { baseColor.opacity(secondaryOpacity) }
    var labelText: Color { baseColor.opacity(labelOpacity) }
}

extension PanelContrast {
    /// The selection fill + ink for ANY surface grey, not only an editor card.
    /// The sidebar draws its rows straight on the page rather than on a card,
    /// so it has no `Ink` to ask — it passes its page grey here and gets the
    /// same pair the editor would have picked for a card of that brightness.
    static func selectionColors(onSurface grey: Double) -> (fill: Color, ink: Color) {
        let dark = selectionIsDarkBlue(onSurface: grey)
        return (Ink.accentColors[dark ? 1 : 2], dark ? .white : .black)
    }
}
