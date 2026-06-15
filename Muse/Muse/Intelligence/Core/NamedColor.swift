import Foundation

/// Maps a hex color to a coarse human name via HSB rules. Pure, deterministic.
///
/// The hard part is the achromatic gate. A near-black charcoal (`#202226`) or a
/// washed-out light tint has a *hue* mathematically, but that hue is just
/// channel noise — naming it "blue"/"purple" is wrong. So before assigning any
/// hue we first decide whether the color is colorful enough to deserve a hue
/// name at all; only then do we read the hue band.
enum NamedColor {
    static func name(forHex hex: String) -> String? {
        guard let (r, g, b) = parse(hex) else { return nil }
        let mx = max(r, g, b), mn = min(r, g, b)
        let delta = mx - mn
        let brightness = mx
        let saturation = mx == 0 ? 0 : delta / mx

        // --- Achromatic gate (brightness/saturation aware) ---
        // Almost no light at all reads black whatever the hue.
        if brightness < 0.13 { return "black" }
        // Dark + weakly-saturated = charcoal / near-black neutral, not a hue
        // (this is what catches noise-hue charcoals like #202226). Genuinely
        // dark *saturated* colors — navy, maroon, deep green — clear this gate
        // and keep their hue, so we must NOT force black on brightness alone.
        if brightness < 0.30 && saturation < 0.35 { return "black" }
        // Low saturation overall = neutral: white when light, gray otherwise.
        if saturation < 0.12 {
            return brightness > 0.90 ? "white" : "gray"
        }

        // --- Chromatic: read the hue band ---
        var hue: Double = 0
        if delta > 0 {
            if mx == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if mx == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue *= 60
            if hue < 0 { hue += 360 }
        }
        if hue >= 15 && hue < 50 {
            if saturation < 0.35 && brightness > 0.75 { return "beige" }
            if brightness < 0.62 { return "brown" }
            return "orange"
        }
        switch hue {
        case ..<15, 345...:
            // Pale, low-saturation warm tones are skin / peach / salmon — they
            // read as pink, not red. Calling them "red" was the dominant source
            // of false "red" tags on portraits and product shots. A true red is
            // either reasonably saturated or not bright-and-washed-out.
            if brightness > 0.8 && saturation < 0.55 { return "pink" }
            // Muted, not-bright warm tones (taupe, mauve, dried-blood, warm-gray)
            // are brown, not red. Saturated darks (maroon) stay red.
            if brightness < 0.7 && saturation < 0.45 { return "brown" }
            return r > 0.85 && b > 0.6 ? "pink" : "red"
        case 50..<70: return "yellow"
        case 70..<160: return "green"
        case 160..<200: return "teal"
        case 200..<255: return "blue"
        case 255..<290: return "purple"
        case 290..<345: return saturation > 0.5 ? "purple" : "pink"
        default: return "gray"
        }
    }

    static func parse(_ hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xff) / 255.0,
                Double((v >> 8) & 0xff) / 255.0,
                Double(v & 0xff) / 255.0)
    }
}
