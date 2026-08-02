//
//  PanelContrast.swift
//  Muse
//
//  Picks the editor panels' ink and card fill so the text always clears WCAG
//  AA on whatever backdrop the user chose.
//
//  The editor's backdrop is a working preference the user sets (white → black),
//  and the panels are translucent cards floating on it. That combination has a
//  dead zone: on MID GREY a white card is barely lighter than the backdrop and
//  white text on it measures 3.6:1 — under AA's 4.5:1 for body text. Guessing a
//  threshold ("light backdrops get dark text") is what produced that bug, so
//  this computes the actual contrast ratio instead.
//
//  The rule, in order:
//    1. Ink is white on a dark backdrop, black on a light one.
//    2. The card is tinted TOWARD the ink, exactly as the Preview column's is
//       (white 0.09 over a dark wash) — that's the look being matched.
//    3. If that fails AA, the tint flips AWAY from the ink and strengthens
//       until it passes. Only the mid greys ever need this.
//    4. Secondary text and card labels start at their designed opacity and are
//       raised only as far as their own targets require.
//
//  Pure math on greys, so it's testable and nothing here needs a view.
//

import Foundation

nonisolated enum PanelContrast {
    /// AA for body text.
    static let bodyTarget = 4.5
    /// The card labels are 10pt. WCAG's 3:1 allowance is for LARGE text (18pt,
    /// or 14pt bold) and these are neither — at 3:1 the INFO/TOOLS headings
    /// were a pale grey on a light card. They're held to the full 4.5.
    static let labelTarget = bodyTarget

    /// WCAG relative luminance of a neutral grey given as an sRGB 0…1 value.
    static func luminance(_ grey: Double) -> Double {
        let c = min(max(grey, 0), 1)
        let linear = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        return linear
    }

    /// WCAG contrast ratio between two neutral greys.
    static func ratio(_ a: Double, _ b: Double) -> Double {
        let la = luminance(a), lb = luminance(b)
        let hi = max(la, lb), lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// `over` composited under `ink` at `opacity`, in sRGB — how SwiftUI draws
    /// a translucent foreground on a card.
    static func composite(ink: Double, over: Double, opacity: Double) -> Double {
        over * (1 - opacity) + ink * opacity
    }

    /// The resolved palette for one backdrop.
    struct Ink: Equatable {
        /// The backdrop this was resolved for, kept so derived surfaces (a
        /// selection wash) can be measured against the same card.
        var backdrop: Double
        /// The ink is black (a light backdrop). White otherwise.
        var isDark: Bool
        /// Opacity of the card's tint veil.
        var cardAlpha: Double
        /// True when the veil is the OPPOSITE colour to the ink (the mid-grey
        /// rescue); false when it's tinted toward the ink like the Preview
        /// column's card.
        var veilOpposesInk: Bool
        var secondaryOpacity: Double
        var labelOpacity: Double

        /// The ink value as a grey, for tests and for composing colours.
        var inkGrey: Double { isDark ? 0 : 1 }
        var veilGrey: Double { veilOpposesInk ? (isDark ? 1 : 0) : inkGrey }
        /// The card's resulting grey on `backdrop`.
        func cardGrey(on backdrop: Double) -> Double {
            PanelContrast.composite(ink: veilGrey, over: backdrop, opacity: cardAlpha)
        }
        var cardGrey: Double { cardGrey(on: backdrop) }

        /// The SELECTED-row fill: a SOLID blue, not a wash.
        ///
        /// The wash it replaces was a different colour on every backdrop — a
        /// pale periwinkle on white, a navy on black — so nothing in the editor
        /// agreed about what "selected" looks like. A solid is one colour per
        /// screen, and it's a darkened or lightened systemBlue rather than
        /// systemBlue itself: white on plain systemBlue is 4.0:1 (macOS's own
        /// selected rows are under AA), and its luminance is near enough the
        /// mid-grey card to vanish against it.
        ///
        /// Dark blue on light cards, light blue on dark ones — whichever
        /// stands out further — each with the ink that clears AA on it.
        var selectionIsDarkBlue: Bool {
            PanelContrast.ratio(PanelContrast.accentGreys[1], cardGrey)
                >= PanelContrast.ratio(PanelContrast.accentGreys[2], cardGrey)
        }
        var selectionSolidGrey: Double {
            PanelContrast.accentGreys[selectionIsDarkBlue ? 1 : 2]
        }
        /// Text and glyphs ON that fill.
        var selectionInkGrey: Double { selectionIsDarkBlue ? 1 : 0 }

        /// The DESTRUCTIVE fill (a delete button), by the same rule: whichever
        /// red stands furthest off this card, with the ink that clears AA on
        /// it. A white glyph on a pale red wash is the failure this replaces.
        var dangerIsDarkRed: Bool {
            PanelContrast.ratio(PanelContrast.dangerGreys[1], cardGrey)
                >= PanelContrast.ratio(PanelContrast.dangerGreys[2], cardGrey)
        }
        var dangerSolidGrey: Double {
            PanelContrast.dangerGreys[dangerIsDarkRed ? 1 : 2]
        }
        var dangerInkGrey: Double { dangerIsDarkRed ? 1 : 0 }
    }

    /// Resolve ink + card for a backdrop brightness (0 black … 1 white).
    static func resolve(backdrop: Double) -> Ink {
        let isDark = backdrop >= 0.5           // light backdrop → black ink
        let ink = isDark ? 0.0 : 1.0
        let baseAlpha = 0.09                   // the Preview column's card

        // 1–2: the Preview column's own card, tinted toward the ink.
        let towardCard = composite(ink: ink, over: backdrop, opacity: baseAlpha)
        var alpha = baseAlpha
        var opposes = false
        var card = towardCard

        // 3: only if that can't carry body text.
        if ratio(ink, towardCard) < bodyTarget {
            opposes = true
            let veil = isDark ? 1.0 : 0.0
            var found = false
            for step in 0...51 {
                let a = baseAlpha + Double(step) * 0.01
                let c = composite(ink: veil, over: backdrop, opacity: a)
                if ratio(ink, c) >= bodyTarget {
                    alpha = a; card = c; found = true; break
                }
            }
            if !found {
                // Unreachable for the five shipped backdrops; clamp rather than
                // return something that silently fails the target.
                alpha = 0.6
                card = composite(ink: veil, over: backdrop, opacity: alpha)
            }
        }

        return Ink(backdrop: backdrop,
                   isDark: isDark,
                   cardAlpha: alpha,
                   veilOpposesInk: opposes,
                   secondaryOpacity: minimumOpacity(ink: ink, card: card,
                                                    desired: 0.62, target: bodyTarget),
                   labelOpacity: minimumOpacity(ink: ink, card: card,
                                                desired: 0.42, target: labelTarget))
    }

    /// The three blues a selection wash can be drawn in, as neutral greys of
    /// the SAME relative luminance. Contrast is a luminance relationship, so a
    /// luminance-matched grey answers the same question the real colour would.
    ///
    /// 0: macOS systemBlue. 1: the same blue darkened. 2: lightened.
    /// Three, because ONE is not enough: systemBlue's luminance (0.51) sits
    /// almost exactly on the mid-grey card (0.44), so on the Mid Gray backdrop
    /// a systemBlue wash is 1.11:1 against the card it's on — a selection you
    /// cannot see. The darker blue separates there.
    static let accentGreys: [Double] = [0.51, 0.28, 0.70]
    /// systemRed, darkened, lightened — as luminance-matched greys. systemRed
    /// itself (0.53) has the same problem systemBlue does: it sits near the
    /// mid-grey card, and white on it is 3.9:1.
    static let dangerGreys: [Double] = [0.53, 0.28, 0.83]
    static let accentGrey = accentGreys[0]
    static let accentGreysDark = accentGreys[1]

    /// A resolved selection wash: which blue, and how much of it.
    struct Selection: Equatable {
        var tintIndex: Int
        var tintGrey: Double
        var alpha: Double
    }

    /// The most VISIBLE selection wash that still leaves the ink at AA.
    ///
    /// Two constraints pull opposite ways: the wash sits under text, so it
    /// can't be loud; and a selection nobody can see is not a selection. So
    /// each blue is taken at the largest alpha its own AA allows, and the one
    /// that separates furthest from the card wins.
    static func selection(over card: Double, ink: Double,
                          preferred: Double = 0.45,
                          target: Double = bodyTarget) -> Selection {
        var best = Selection(tintIndex: 0, tintGrey: accentGreys[0], alpha: 0)
        var bestSeparation = 0.0
        for (index, tint) in accentGreys.enumerated() {
            let alpha = selectionAlpha(over: card, tint: tint, ink: ink,
                                       preferred: preferred, target: target)
            guard alpha > 0 else { continue }
            let separation = ratio(composite(ink: tint, over: card, opacity: alpha), card)
            if separation > bestSeparation {
                bestSeparation = separation
                best = Selection(tintIndex: index, tintGrey: tint, alpha: alpha)
            }
        }
        return best
    }

    /// `preferred` is the CEILING, not the value: the search takes the largest
    /// wash the ink can still sit on, so a selected row is as visible as AA
    /// allows on that backdrop rather than uniformly timid.
    static func selectionAlpha(over card: Double, tint: Double = accentGreys[0],
                               ink: Double, preferred: Double = 0.45,
                               target: Double = bodyTarget) -> Double {
        var alpha = preferred
        while alpha > 0 {
            if ratio(ink, composite(ink: tint, over: card, opacity: alpha)) >= target {
                return alpha
            }
            alpha -= 0.01
        }
        return 0
    }

    /// The smallest opacity ≥ `desired` at which ink on `card` clears `target`.
    static func minimumOpacity(ink: Double, card: Double,
                               desired: Double, target: Double) -> Double {
        var opacity = desired
        while opacity < 1.0 {
            if ratio(composite(ink: ink, over: card, opacity: opacity), card) >= target {
                return opacity
            }
            opacity += 0.01
        }
        return 1.0
    }
}
