import Foundation

/// Turns a palette into a small set of color tag labels. Pure + deterministic.
///
/// The old rule — tag *every* one of the top-3 palette clusters — meant a
/// minor accent (or a portrait's skin tone in the 3rd cluster) tagged the whole
/// image. Here a color only becomes a tag if its cluster actually covers a
/// meaningful share of the image; the single dominant cluster is always named.
enum ColorTagger {
    /// Color tags from a weighted palette (hex + share 0…1, sorted descending).
    /// Always names the dominant cluster; names others only if they cover at
    /// least `minShare`. Deduped by name, capped at `maxTags`.
    static func tags(fromWeighted palette: [(String, Double)],
                     minShare: Double = 0.15,
                     maxTags: Int = 3) -> [String] {
        var out: [String] = []
        for (index, entry) in palette.enumerated() {
            if index > 0 && entry.1 < minShare { continue }
            guard let name = NamedColor.name(forHex: entry.0) else { continue }
            if !out.contains(name) { out.append(name) }
            if out.count >= maxTags { break }
        }
        return out
    }
}
