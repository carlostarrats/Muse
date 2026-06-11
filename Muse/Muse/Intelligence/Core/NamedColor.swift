import Foundation

/// Maps a hex color to a coarse human name via HSB rules. Pure, deterministic.
enum NamedColor {
    static func name(forHex hex: String) -> String? {
        guard let (r, g, b) = parse(hex) else { return nil }
        let mx = max(r, g, b), mn = min(r, g, b)
        let delta = mx - mn
        let brightness = mx
        let saturation = mx == 0 ? 0 : delta / mx

        if brightness < 0.13 { return "black" }
        if saturation < 0.10 {
            if brightness > 0.92 { return "white" }
            return "gray"
        }
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
        case ..<15, 345...: return r > 0.85 && b > 0.6 ? "pink" : "red"
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
