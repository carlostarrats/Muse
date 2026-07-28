import SwiftUI

/// Frosted blur of the app content + a translucent wash of the image's dominant
/// colour, darkened.
///
/// The hero-open flicker on large images had TWO independent causes, found by
/// A/B substitution after five wrong guesses. Both fixes are load-bearing:
///
/// 1. **Never animate opacity on the material.** `.ultraThinMaterial`
///    re-composites its blur every frame while its opacity animates, and the
///    stepping is visible. Proven by substitution: a flat colour with the
///    identical animation never flickered, while disabling the grid content
///    behind the blur changed nothing. `compositingGroup()` did not help. So the
///    wash does NOT fade in — it is at full strength from the first frame.
///
/// 2. **The tint's opacity must be CONSTANT.** It used to be
///    `hexColor == nil ? 0.45 : 0.78`, so when the tint resolved (~50ms in) the
///    layer changed colour AND opacity at once. That double jump reads as a
///    flicker on its own — it survived removing the material entirely. Only the
///    COLOUR changes now, and a plain colour cross-fades cleanly.
///
/// It still fades OUT on close: the close flight depends on the backdrop being
/// gone before the subtree unmounts at 0.36s, or a layer ripped away
/// mid-opacity reads as a whole-window flash.
struct ViewerBackdrop: View {
    var hexColor: String?    // dominant color; nil → neutral dark
    /// The REAL close state — never merely "not yet visible". Conflating them
    /// puts the wash at opacity 0 on mount and snaps it to 1, which is a flash.
    var closing: Bool = false

    private var tint: Color {
        guard let hex = hexColor, let (r, g, b) = NamedColor.parse(hex) else {
            // Neutral start. Deliberately close in weight to a typical tint, so
            // the cross-fade to the real colour is a hue shift rather than a
            // brightness jump.
            return Color(red: 0.17, green: 0.17, blue: 0.19)
        }
        let k = 0.55   // darken, matching the prototype's tintColor()
        return Color(red: r * k, green: g * k, blue: b * k)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            // CONSTANT opacity — see rule 2 above. Do not make this depend on
            // whether the tint has resolved.
            tint.opacity(0.78)
        }
        .opacity(closing ? 0 : 1)
        // Colour cross-fade only; no opacity animation on the way in.
        .animation(.easeInOut(duration: 0.5), value: hexColor)
        .animation(.easeOut(duration: 0.3), value: closing)
        .ignoresSafeArea()
        // Purely a decorative wash — VoiceOver shouldn't stop on it (the viewer's
        // close affordance is the ✕ chrome button; the tap-to-close is mouse-only).
        .accessibilityHidden(true)
    }
}
