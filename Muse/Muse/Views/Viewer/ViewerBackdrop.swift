import SwiftUI

/// Frosted blur of the app content + a translucent wash of the image's
/// dominant color darkened ~45%. Color cross-fades on arrow-key flips.
struct ViewerBackdrop: View {
    var hexColor: String?    // dominant color; nil → neutral dark

    private var tint: Color {
        guard let hex = hexColor, let (r, g, b) = NamedColor.parse(hex) else {
            return Color(red: 0.16, green: 0.16, blue: 0.18)
        }
        let k = 0.55   // darken, matching the prototype's tintColor()
        return Color(red: r * k, green: g * k, blue: b * k)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            // Prototype: blur(30px) brightness(.5) + rgba(dominant·0.55, 0.78).
            // While the tint is unknown (a beat at most — it's computed on
            // open), stay light so the blurred grid shows through instead of
            // crushing to black.
            tint.opacity(hexColor == nil ? 0.45 : 0.78)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: hexColor)
        // Purely a decorative wash — VoiceOver shouldn't stop on it (the viewer's
        // close affordance is the ✕ chrome button; the tap-to-close is mouse-only).
        .accessibilityHidden(true)
    }
}
