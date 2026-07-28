import SwiftUI

/// Opaque wash behind the hero viewers, tinted by the image's dominant color.
///
/// **Deliberately NOT a material.** This was `.ultraThinMaterial` + a translucent
/// tint, and it flickered on every hero open of a large image. Six attempts and
/// two A/B tests pinned the cause: animating opacity on a macOS material
/// re-composites its blur every frame, and the stepping is visible. Proven by
/// substitution — a flat colour with the identical animation never flickered,
/// while disabling the grid content behind the blur changed nothing. Owner
/// decision (2026-07-28): drop the blur for a static colour. It can't flicker by
/// construction, costs nothing to composite, and removes a whole class of
/// fragile material/animation interactions.
///
/// Two rules keep it artefact-free — don't break either:
///
/// 1. **Opacity is constant while open.** It does NOT fade in. Only the tint
///    CHANGES, and a plain colour cross-fades cleanly. The original faded
///    opacity and morphed colour simultaneously, which read as a flicker even
///    without the material.
/// 2. **It still fades OUT on close.** The close flight depends on the backdrop
///    being gone before the subtree unmounts at 0.36s; a layer ripped away
///    mid-opacity reads as a whole-window flash.
struct ViewerBackdrop: View {
    var hexColor: String?    // dominant color; nil → neutral dark
    /// The REAL close state — never merely "not yet visible". Conflating them
    /// puts the wash at opacity 0 on mount and snaps it to 1, which is a flash.
    var closing: Bool = false

    private var tint: Color {
        guard let hex = hexColor, let (r, g, b) = NamedColor.parse(hex) else {
            return Color(red: 0.13, green: 0.13, blue: 0.145)
        }
        // Darken, matching the prototype's tintColor().
        let k = 0.42
        return Color(red: r * k, green: g * k, blue: b * k)
    }

    var body: some View {
        ZStack {
            tint
            // A soft vignette so the wash reads as a lit surface rather than a
            // flat fill — the depth the blur used to provide, at no compositing
            // cost and with nothing to animate.
            RadialGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.35)],
                center: .center, startRadius: 120, endRadius: 900)
        }
        .opacity(closing ? 0 : 1)
        // Colour cross-fade only. NO opacity animation on the way in.
        .animation(.easeInOut(duration: 0.5), value: hexColor)
        .animation(.easeOut(duration: 0.3), value: closing)
        .ignoresSafeArea()
        // Purely a decorative wash — VoiceOver shouldn't stop on it (the viewer's
        // close affordance is the ✕ chrome button; the tap-to-close is mouse-only).
        .accessibilityHidden(true)
    }
}
