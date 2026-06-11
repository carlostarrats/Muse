import SwiftUI

/// Frosted blur of the app content + a translucent wash of the image's
/// dominant color darkened ~45%. Color cross-fades on arrow-key flips.
struct ViewerBackdrop: View {
    var hexColor: String?    // dominant color; nil → neutral dark

    private var tint: Color {
        guard let hex = hexColor, let (r, g, b) = NamedColor.parse(hex) else {
            return Color(red: 0.08, green: 0.08, blue: 0.09)
        }
        let k = 0.55   // darken
        return Color(red: r * k, green: g * k, blue: b * k)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            tint.opacity(0.78)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: hexColor)
    }
}
